import Conduit
import Foundation

// MARK: - Low-level fan-out primitives

extension Sewn {
    /// Fan search out to all active Thread nodes. Sewn passes `queryText` (raw string);
    /// each Thread embeds it locally before running its hybrid KG + PQ search.
    /// Returns the merged results plus a merged graph trace (entity matches and
    /// expansion edges unioned across nodes).
    nonisolated func fanoutSearch(
        queryText: String,
        request: SewnRequest,
        topK: Int = 3
    ) async -> (results: [Thread_V1_ThreadPartitionResult], trace: Thread_V1_ThreadGraphTrace?) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], nil) }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return ([], nil) }

        var req = Thread_V1_ThreadSearchRequest()
        req.queryText = queryText
        req.queryEmbedding = []
        req.queryEntityEmbedding = []
        req.entities = request.entities ?? request.tags ?? []
        req.ownerID = request.ownerId
        req.scope = request.scope?.rawValue ?? "global"
        req.topK = Int32(topK)
        var groupIds = request.groups?.map(\.id) ?? []
        if let gid = request.group?.id { groupIds.append(gid) }
        req.groupIds = groupIds
        req.aggregate = request.aggregate ?? false

        return await withTaskGroup(of: Thread_V1_ThreadSearchResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    try? await client.search(req, thread: node)
                }
            }
            var all: [Thread_V1_ThreadPartitionResult] = []
            var matchedEntityIds = Set<String>()
            var expansionEdgeIds = Set<String>()
            var expandedDocumentCount: Int32 = 0
            var sawTrace = false
            for await response in group {
                guard let response else { continue }
                all.append(contentsOf: response.results)
                if response.hasTrace {
                    sawTrace = true
                    matchedEntityIds.formUnion(response.trace.matchedEntityIds)
                    expansionEdgeIds.formUnion(response.trace.expansionEdgeIds)
                    expandedDocumentCount += response.trace.expandedDocumentCount
                }
            }
            var mergedTrace: Thread_V1_ThreadGraphTrace?
            if sawTrace {
                var t = Thread_V1_ThreadGraphTrace()
                t.matchedEntityIds = Array(matchedEntityIds)
                t.expansionEdgeIds = Array(expansionEdgeIds)
                t.expandedDocumentCount = expandedDocumentCount
                mergedTrace = t
            }
            return (all.sorted { $0.score < $1.score }, mergedTrace)
        }
    }

    /// Route index items to a specific Thread node, or pick the first node available for storage.
    /// If `request.threadIds` is set, targets the first matching active node.
    /// Returns `(success, threadId)` — threadId is the UUID string of the node used.
    @discardableResult
    nonisolated func fanoutIndex(
        items: [Sewn.BatchPutItem],
        request: SewnRequest,
        targetNode: ThreadNode? = nil
    ) async -> (success: Bool, threadId: String?) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return (false, nil) }

        let node: ThreadNode
        if let targetNode {
            node = targetNode
        } else if let ids = request.threadIds, !ids.isEmpty {
            let allNodes = await nonisolatedRegistryMutator.activeNodes
            guard let matched = allNodes.first(where: { ids.contains($0.threadId.uuidString) }) else {
                logger.warning("fanoutIndex: requested threadIds \(ids) not found among active nodes", service: .sewn, request: request)
                return (false, nil)
            }
            node = matched
        } else {
            guard let picked = await nonisolatedRegistryMutator.availableForStorage.first else {
                // TODO: trigger automatic Thread spawn when no node is available for storage.
                // Sewn will eventually provision a new Thread, register it, and it will appear
                // in availableForStorage — at which point putBatch's retry loop will succeed.
                logger.warning("fanoutIndex: no Thread available for storage", service: .sewn, request: request)
                return (false, nil)
            }
            node = picked
        }

        var req = Thread_V1_ThreadIndexRequest()
        req.ownerID = request.ownerId
        req.groupID = request.group?.id ?? ""
        req.groupLabel = request.group?.label ?? ""
        req.scope = request.scope?.rawValue ?? "personal"
        req.items = items.map { item in
            var protoItem = Thread_V1_ThreadIndexItem()
            protoItem.documentID = item.id
            protoItem.texts = item.texts
            protoItem.tags = item.tags
            protoItem.metadata = item.metadata ?? Data()
            protoItem.mediaType = item.mediaType == .image ? "image" : "text"
            if !item.name.isNilOrEmpty { protoItem.name = item.name ?? "" }
            return protoItem
        }

        let threadIdStr = node.threadId.uuidString
        guard let resp = try? await client.index(req, thread: node) else {
            logger.warning("fanoutIndex: no response from Thread \(node.threadId) — session may have dropped", service: .sewn, request: request)
            return (false, threadIdStr)
        }
        if !resp.success {
            logger.warning("fanoutIndex: Thread \(node.threadId) signalled backpressure (success=false)", service: .sewn, request: request)
            return (false, threadIdStr)
        }
        return (true, threadIdStr)
    }

    /// Removes `documentIds` from Thread nodes.
    /// - `targetThreadIds`: when non-nil, only sends to those specific Thread UUIDs;
    ///   when nil (default), broadcasts to all active nodes.
    nonisolated func fanoutRemove(
        documentIds: [String],
        ownerId: String,
        targetThreadIds: [String]? = nil
    ) async {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return }
        let allNodes = await nonisolatedRegistryMutator.activeNodes
        let nodes: [ThreadNode]
        if let ids = targetThreadIds {
            nodes = allNodes.filter { ids.contains($0.threadId.uuidString) }
        } else {
            nodes = allNodes
        }
        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    var req = Thread_V1_ThreadRemoveRequest()
                    req.ownerID = ownerId
                    req.documentIds = documentIds
                    _ = try? await client.remove(req, thread: node)
                }
            }
        }
    }
}

// MARK: - Library fan-out

/// Sentinel URL used in stub documents returned from paginated list responses.
/// The full URL is never needed in a list row — only the document ID — so we
/// ship only the ID and skip the URL parsing + serialization cost for every
/// document on every page.
private let stubDocumentURL = URL(string: "https://sewn.invalid")!

/// Full conversion — used for leaderboard, search, and any non-paginated path
/// where downstream code needs actual document metadata.
private func convertThreadGroup(_ pg: Thread_V1_ThreadGroup) -> Sewn.Group {
    let docs: [Sewn.Document] = pg.documents.map { pd in
        Sewn.Document(
            id: pd.id,
            url: URL(string: pd.url) ?? URL(string: "file://unknown")!,
            ownerId: pd.ownerID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(pd.createdAt))
        )
    }
    let access: SewnRegistry.Access? = pg.access.isEmpty ? nil
        : SewnRegistry.Access(rawValue: pg.access)
    let metadata: Sewn.Group.Metadata? = (pg.groupDescription.isEmpty && pg.tags.isEmpty) ? nil
        : Sewn.Group.Metadata(
            description: pg.groupDescription.isEmpty ? nil : pg.groupDescription,
            tags: Array(pg.tags)
          )
    return Sewn.Group(
        id: pg.id,
        label: pg.label,
        ownerId: pg.ownerID,
        documents: docs,
        access: access,
        totalEarnings: pg.totalEarnings == 0 ? nil : pg.totalEarnings,
        metadata: metadata
    )
}

/// Light conversion for paginated list responses — documents are replaced with
/// ID-only stubs so we skip URL parsing and avoid serializing hundreds of URL
/// strings, ownerIds, and timestamps on every page fetch.  The stub URL is a
/// sentinel that callers use to suppress display; the real URL loads on demand
/// when the user taps into a document.
private func convertThreadGroupLight(_ pg: Thread_V1_ThreadGroup) -> Sewn.Group {
    let stubs: [Sewn.Document] = pg.documents.map { pd in
        Sewn.Document(id: pd.id, url: stubDocumentURL, ownerId: "", createdAt: .distantPast)
    }
    let access: SewnRegistry.Access? = pg.access.isEmpty ? nil
        : SewnRegistry.Access(rawValue: pg.access)
    let metadata: Sewn.Group.Metadata? = (pg.groupDescription.isEmpty && pg.tags.isEmpty) ? nil
        : Sewn.Group.Metadata(
            description: pg.groupDescription.isEmpty ? nil : pg.groupDescription,
            tags: Array(pg.tags)
          )
    return Sewn.Group(
        id: pg.id,
        label: pg.label,
        ownerId: pg.ownerID,
        documents: stubs,
        access: access,
        totalEarnings: pg.totalEarnings == 0 ? nil : pg.totalEarnings,
        metadata: metadata
    )
}

private func mergeThreadGroups(_ threadGroups: [Sewn.Group], into groupMap: inout [String: Sewn.Group]) {
    for threadGroup in threadGroups {
        if var existing = groupMap[threadGroup.id] {
            var seenIds = Set(existing.documents.map { $0.id })
            for doc in threadGroup.documents where seenIds.insert(doc.id).inserted {
                existing.documents.append(doc)
            }
            groupMap[threadGroup.id] = existing
        } else {
            groupMap[threadGroup.id] = threadGroup
        }
    }
}

extension Sewn {
    /// Fans out gRPC Library to active Thread nodes and coalesces results.
    ///
    /// - Parameters:
    ///   - limit: When set, fetches one page of this size from each Thread using `afterId` as the
    ///     cursor. When nil, fetches all pages and returns the full library.
    ///   - afterId: Anchor cursor (group id) for the next page; empty = start of list.
    ///   - threadIds: When set, only fans out to Threads whose UUID is in this list.
    nonisolated func fanoutLibrary(
        ownerId: String,
        limit: Int? = nil,
        afterId: String = "",
        threadIds: [String]? = nil
    ) async -> (groups: [Sewn.Group], hasMore: Bool, nextAfterId: String) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], false, "") }
        let allNodes = await nonisolatedRegistryMutator.activeNodes
        let nodes: [ThreadNode]
        if let ids = threadIds, !ids.isEmpty {
            nodes = allNodes.filter { ids.contains($0.threadId.uuidString) }
        } else if !ownerId.isEmpty {
            nodes = await nonisolatedRegistryMutator.threadNodesForOwner(ownerId, allNodes: allNodes)
        } else {
            nodes = allNodes
        }
        guard !nodes.isEmpty else { return ([], false, "") }

        var groupMap: [String: Sewn.Group] = [:]
        var hasMore = false

        if let limit {
            // Single-page fetch: one gRPC request per Thread with the caller's cursor/limit.
            await withTaskGroup(of: (groups: [Sewn.Group], hasMore: Bool).self) { group in
                for node in nodes {
                    group.addTask {
                        var req = Thread_V1_ThreadLibraryRequest()
                        req.ownerID          = ownerId
                        req.includeAvailable = true
                        req.limit            = Int32(limit)
                        req.afterID          = afterId
                        req.threadID          = node.threadId.uuidString
                        guard let resp = try? await client.library(req, thread: node) else { return ([], false) }
                        if !resp.groups.isEmpty && !ownerId.isEmpty {
                            await self.nonisolatedRegistryMutator.recordOwnerThread(
                                ownerId: ownerId, threadId: node.threadId
                            )
                        }
                        return (resp.groups.map(convertThreadGroupLight), resp.hasMore_p)
                    }
                }
                for await (groups, nodeHasMore) in group {
                    hasMore = hasMore || nodeHasMore
                    mergeThreadGroups(groups, into: &groupMap)
                }
            }
        } else {
            // Full multi-page fetch: loop until each Thread reports no more pages.
            let pageSize: Int32 = 200
            await withTaskGroup(of: [Sewn.Group].self) { group in
                for node in nodes {
                    group.addTask {
                        var pageGroups: [Sewn.Group] = []
                        var cursor = ""
                        var recorded = false
                        repeat {
                            var req = Thread_V1_ThreadLibraryRequest()
                            req.ownerID          = ownerId
                            req.includeAvailable = true
                            req.limit            = pageSize
                            req.afterID          = cursor
                            req.threadID          = node.threadId.uuidString
                            guard let resp = try? await client.library(req, thread: node) else { break }
                            if !recorded && !resp.groups.isEmpty && !ownerId.isEmpty {
                                await self.nonisolatedRegistryMutator.recordOwnerThread(
                                    ownerId: ownerId, threadId: node.threadId
                                )
                                recorded = true
                            }
                            pageGroups.append(contentsOf: resp.groups.map(convertThreadGroup))
                            cursor = resp.groups.last?.id ?? ""
                            if !resp.hasMore_p { break }
                        } while true
                        return pageGroups
                    }
                }
                for await groups in group {
                    mergeThreadGroups(groups, into: &groupMap)
                }
            }
        }

        let sorted = Array(groupMap.values).sorted { $0.id < $1.id }
        return (sorted, hasMore, sorted.last?.id ?? "")
    }

    /// Fans out a document-ID-filtered Library request to targeted Thread nodes.
    /// Uses the Thread's reverse `documentGroups` map — no full library scan.
    /// Returns matching groups and a documentId → groupId map.
    nonisolated func fanoutLibraryByDocuments(
        ownerId: String,
        documentIds: [String],
        threadIds: [String]? = nil
    ) async -> (groups: [Sewn.Group], documentGroups: [String: String]) {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], [:]) }
        let allNodes = await nonisolatedRegistryMutator.activeNodes
        let nodes: [ThreadNode]
        if let ids = threadIds, !ids.isEmpty {
            nodes = allNodes.filter { ids.contains($0.threadId.uuidString) }
        } else if !ownerId.isEmpty {
            nodes = await nonisolatedRegistryMutator.threadNodesForOwner(ownerId, allNodes: allNodes)
        } else {
            nodes = allNodes
        }
        guard !nodes.isEmpty else { return ([], [:]) }

        var groupMap: [String: Sewn.Group] = [:]

        await withTaskGroup(of: [Sewn.Group].self) { group in
            for node in nodes {
                group.addTask {
                    var req = Thread_V1_ThreadLibraryRequest()
                    req.ownerID     = ownerId
                    req.threadID     = node.threadId.uuidString
                    req.documentIds = documentIds
                    guard let resp = try? await client.library(req, thread: node) else { return [] }
                    return resp.groups.map(convertThreadGroup)
                }
            }
            for await groups in group {
                mergeThreadGroups(groups, into: &groupMap)
            }
        }

        let sorted = Array(groupMap.values).sorted { $0.id < $1.id }

        let requestedSet = Set(documentIds)
        var documentGroupMap: [String: String] = [:]
        for group in sorted {
            for doc in group.documents where requestedSet.contains(doc.id) {
                documentGroupMap[doc.id] = group.id
            }
        }

        return (sorted, documentGroupMap)
    }
}

// MARK: - Graph fan-out

extension Sewn {
    /// Fans out a knowledge-graph query to all active Thread nodes and merges the
    /// results: entities dedupe by id (mention counts summed, max score), relationships
    /// dedupe by id (weights summed), documents dedupe by id, stats summed.
    nonisolated func fanoutGraph(
        ownerId: String,
        entity: String? = nil,
        query: String? = nil,
        kinds: [String] = [],
        hops: Int = 1,
        limit: Int = 20,
        includeDocuments: Bool = true
    ) async -> Thread_V1_ThreadGraphQueryResponse {
        var merged = Thread_V1_ThreadGraphQueryResponse()
        guard let client = _threadQueryClient as? ThreadQueryClient else { return merged }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return merged }

        var req = Thread_V1_ThreadGraphQueryRequest()
        req.ownerID = ownerId
        req.entity = entity ?? ""
        req.query = query ?? ""
        req.kinds = kinds
        req.hops = Int32(hops)
        req.limit = Int32(limit)
        req.includeDocuments = includeDocuments

        let responses = await withTaskGroup(of: Thread_V1_ThreadGraphQueryResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    try? await client.graph(req, thread: node)
                }
            }
            var all: [Thread_V1_ThreadGraphQueryResponse] = []
            for await response in group {
                if let response { all.append(response) }
            }
            return all
        }

        var entitiesById: [String: Thread_V1_ThreadGraphEntity] = [:]
        var relationshipsById: [String: Thread_V1_ThreadGraphRelationship] = [:]
        var documentsById: [String: Thread_V1_ThreadGraphDocument] = [:]
        var stats = Thread_V1_ThreadGraphStats()

        for response in responses {
            for e in response.entities {
                if var existing = entitiesById[e.id] {
                    existing.mentionCount += e.mentionCount
                    existing.score = max(existing.score, e.score)
                    existing.documentIds = Array(Set(existing.documentIds + e.documentIds)).sorted()
                    entitiesById[e.id] = existing
                } else {
                    entitiesById[e.id] = e
                }
            }
            for r in response.relationships {
                if var existing = relationshipsById[r.id] {
                    existing.weight += r.weight
                    existing.documentIds = Array(Set(existing.documentIds + r.documentIds)).sorted()
                    relationshipsById[r.id] = existing
                } else {
                    relationshipsById[r.id] = r
                }
            }
            for d in response.documents where documentsById[d.id] == nil {
                documentsById[d.id] = d
            }
            stats.entityCount += response.stats.entityCount
            stats.relationshipCount += response.stats.relationshipCount
        }

        merged.entities = entitiesById.values.sorted { $0.score > $1.score }
        merged.relationships = relationshipsById.values.sorted { $0.weight > $1.weight }
        merged.documents = documentsById.values.sorted { $0.id < $1.id }
        merged.stats = stats
        return merged
    }
}

// MARK: - Update fan-out

extension Sewn {
    /// Broadcasts a group access/label/metadata update to all active Thread nodes.
    /// Returns true if at least one Thread confirmed success.
    @discardableResult
    nonisolated func fanoutUpdateGroup(
        groupId: String,
        ownerId: String,
        access: String?,
        label: String?,
        description: String?,
        tags: [String]?,
        updateMetadata: Bool = false
    ) async -> Bool {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return false }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return false }

        var req = Thread_V1_ThreadUpdateGroupRequest()
        req.ownerID = ownerId
        req.groupID = groupId
        if let access { req.access = access }
        if let label { req.label = label }
        if updateMetadata {
            req.updateMetadata = true
            req.groupDescription = description ?? ""
            req.tags = tags ?? []
        }

        return await withTaskGroup(of: Bool.self) { group in
            for node in nodes {
                group.addTask {
                    (try? await client.updateGroup(req, thread: node))?.success ?? false
                }
            }
            var anySuccess = false
            for await success in group { anySuccess = anySuccess || success }
            return anySuccess
        }
    }

    /// Broadcasts a document access/group update to all active Thread nodes.
    /// Returns true if at least one Thread confirmed success.
    @discardableResult
    nonisolated func fanoutUpdateDocument(
        documentId: String,
        ownerId: String,
        access: String?,
        groupId: String?
    ) async -> Bool {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return false }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return false }

        var req = Thread_V1_ThreadUpdateDocumentRequest()
        req.ownerID = ownerId
        req.documentID = documentId
        if let access { req.access = access }
        if let groupId { req.groupID = groupId }

        return await withTaskGroup(of: Bool.self) { group in
            for node in nodes {
                group.addTask {
                    (try? await client.updateDocument(req, thread: node))?.success ?? false
                }
            }
            var anySuccess = false
            for await success in group { anySuccess = anySuccess || success }
            return anySuccess
        }
    }

    /// Fetches registry stats from all active Thread nodes in parallel.
    /// Returns a map of threadId (UUID string) → stats response.
    nonisolated func fanoutStats() async -> [String: Thread_V1_ThreadStatsResponse] {
        guard let client = _threadQueryClient as? ThreadQueryClient else { return [:] }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return [:] }

        let req = Thread_V1_ThreadStatsRequest()
        return await withTaskGroup(of: (String, Thread_V1_ThreadStatsResponse?).self) { group in
            for node in nodes {
                group.addTask {
                    let resp = try? await client.stats(req, thread: node)
                    return (node.threadId.uuidString, resp)
                }
            }
            var result: [String: Thread_V1_ThreadStatsResponse] = [:]
            for await (threadId, resp) in group {
                if let resp { result[threadId] = resp }
            }
            return result
        }
    }
}

// MARK: - Private helpers

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
