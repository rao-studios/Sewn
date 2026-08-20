import Conduit
import Foundation

// MARK: - Low-level fan-out primitives

extension Seer {
    /// Fan search out to all active Totem nodes. Seer passes `queryText` (raw string);
    /// each Totem embeds it locally before running its hybrid KG + PQ search.
    /// Returns the merged results plus a merged graph trace (entity matches and
    /// expansion edges unioned across nodes).
    nonisolated func fanoutSearch(
        queryText: String,
        request: SeerRequest,
        topK: Int = 3
    ) async -> (results: [Totem_V1_TotemPartitionResult], trace: Totem_V1_TotemGraphTrace?) {
        guard let client = _totemQueryClient as? TotemQueryClient else { return ([], nil) }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return ([], nil) }

        var req = Totem_V1_TotemSearchRequest()
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

        return await withTaskGroup(of: Totem_V1_TotemSearchResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    try? await client.search(req, totem: node)
                }
            }
            var all: [Totem_V1_TotemPartitionResult] = []
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
            var mergedTrace: Totem_V1_TotemGraphTrace?
            if sawTrace {
                var t = Totem_V1_TotemGraphTrace()
                t.matchedEntityIds = Array(matchedEntityIds)
                t.expansionEdgeIds = Array(expansionEdgeIds)
                t.expandedDocumentCount = expandedDocumentCount
                mergedTrace = t
            }
            return (all.sorted { $0.score < $1.score }, mergedTrace)
        }
    }

    /// Route index items to a specific Totem node, or pick the first node available for storage.
    /// If `request.totemIds` is set, targets the first matching active node.
    /// Returns `(success, totemId)` — totemId is the UUID string of the node used.
    @discardableResult
    nonisolated func fanoutIndex(
        items: [Seer.BatchPutItem],
        request: SeerRequest,
        targetNode: TotemNode? = nil
    ) async -> (success: Bool, totemId: String?) {
        guard let client = _totemQueryClient as? TotemQueryClient else { return (false, nil) }

        let node: TotemNode
        if let targetNode {
            node = targetNode
        } else if let ids = request.totemIds, !ids.isEmpty {
            let allNodes = await nonisolatedRegistryMutator.activeNodes
            guard let matched = allNodes.first(where: { ids.contains($0.totemId.uuidString) }) else {
                logger.warning("fanoutIndex: requested totemIds \(ids) not found among active nodes", service: .seer, request: request)
                return (false, nil)
            }
            node = matched
        } else {
            guard let picked = await nonisolatedRegistryMutator.availableForStorage.first else {
                // TODO: trigger automatic Totem spawn when no node is available for storage.
                // Seer will eventually provision a new Totem, register it, and it will appear
                // in availableForStorage — at which point putBatch's retry loop will succeed.
                logger.warning("fanoutIndex: no Totem available for storage", service: .seer, request: request)
                return (false, nil)
            }
            node = picked
        }

        var req = Totem_V1_TotemIndexRequest()
        req.ownerID = request.ownerId
        req.groupID = request.group?.id ?? ""
        req.groupLabel = request.group?.label ?? ""
        req.scope = request.scope?.rawValue ?? "personal"
        req.items = items.map { item in
            var protoItem = Totem_V1_TotemIndexItem()
            protoItem.documentID = item.id
            protoItem.texts = item.texts
            protoItem.tags = item.tags
            protoItem.metadata = item.metadata ?? Data()
            protoItem.mediaType = item.mediaType == .image ? "image" : "text"
            if !item.name.isNilOrEmpty { protoItem.name = item.name ?? "" }
            return protoItem
        }

        let totemIdStr = node.totemId.uuidString
        guard let resp = try? await client.index(req, totem: node) else {
            logger.warning("fanoutIndex: no response from Totem \(node.totemId) — session may have dropped", service: .seer, request: request)
            return (false, totemIdStr)
        }
        if !resp.success {
            logger.warning("fanoutIndex: Totem \(node.totemId) signalled backpressure (success=false)", service: .seer, request: request)
            return (false, totemIdStr)
        }
        return (true, totemIdStr)
    }

    /// Removes `documentIds` from Totem nodes.
    /// - `targetTotemIds`: when non-nil, only sends to those specific Totem UUIDs;
    ///   when nil (default), broadcasts to all active nodes.
    nonisolated func fanoutRemove(
        documentIds: [String],
        ownerId: String,
        targetTotemIds: [String]? = nil
    ) async {
        guard let client = _totemQueryClient as? TotemQueryClient else { return }
        let allNodes = await nonisolatedRegistryMutator.activeNodes
        let nodes: [TotemNode]
        if let ids = targetTotemIds {
            nodes = allNodes.filter { ids.contains($0.totemId.uuidString) }
        } else {
            nodes = allNodes
        }
        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    var req = Totem_V1_TotemRemoveRequest()
                    req.ownerID = ownerId
                    req.documentIds = documentIds
                    _ = try? await client.remove(req, totem: node)
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
private let stubDocumentURL = URL(string: "https://seer.invalid")!

/// Full conversion — used for leaderboard, search, and any non-paginated path
/// where downstream code needs actual document metadata.
private func convertTotemGroup(_ pg: Totem_V1_TotemGroup) -> Seer.Group {
    let docs: [Seer.Document] = pg.documents.map { pd in
        Seer.Document(
            id: pd.id,
            url: URL(string: pd.url) ?? URL(string: "file://unknown")!,
            ownerId: pd.ownerID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(pd.createdAt))
        )
    }
    let access: SeerRegistry.Access? = pg.access.isEmpty ? nil
        : SeerRegistry.Access(rawValue: pg.access)
    let metadata: Seer.Group.Metadata? = (pg.groupDescription.isEmpty && pg.tags.isEmpty) ? nil
        : Seer.Group.Metadata(
            description: pg.groupDescription.isEmpty ? nil : pg.groupDescription,
            tags: Array(pg.tags)
          )
    return Seer.Group(
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
private func convertTotemGroupLight(_ pg: Totem_V1_TotemGroup) -> Seer.Group {
    let stubs: [Seer.Document] = pg.documents.map { pd in
        Seer.Document(id: pd.id, url: stubDocumentURL, ownerId: "", createdAt: .distantPast)
    }
    let access: SeerRegistry.Access? = pg.access.isEmpty ? nil
        : SeerRegistry.Access(rawValue: pg.access)
    let metadata: Seer.Group.Metadata? = (pg.groupDescription.isEmpty && pg.tags.isEmpty) ? nil
        : Seer.Group.Metadata(
            description: pg.groupDescription.isEmpty ? nil : pg.groupDescription,
            tags: Array(pg.tags)
          )
    return Seer.Group(
        id: pg.id,
        label: pg.label,
        ownerId: pg.ownerID,
        documents: stubs,
        access: access,
        totalEarnings: pg.totalEarnings == 0 ? nil : pg.totalEarnings,
        metadata: metadata
    )
}

private func mergeTotemGroups(_ totemGroups: [Seer.Group], into groupMap: inout [String: Seer.Group]) {
    for totemGroup in totemGroups {
        if var existing = groupMap[totemGroup.id] {
            var seenIds = Set(existing.documents.map { $0.id })
            for doc in totemGroup.documents where seenIds.insert(doc.id).inserted {
                existing.documents.append(doc)
            }
            groupMap[totemGroup.id] = existing
        } else {
            groupMap[totemGroup.id] = totemGroup
        }
    }
}

extension Seer {
    /// Fans out gRPC Library to active Totem nodes and coalesces results.
    ///
    /// - Parameters:
    ///   - limit: When set, fetches one page of this size from each Totem using `afterId` as the
    ///     cursor. When nil, fetches all pages and returns the full library.
    ///   - afterId: Anchor cursor (group id) for the next page; empty = start of list.
    ///   - totemIds: When set, only fans out to Totems whose UUID is in this list.
    nonisolated func fanoutLibrary(
        ownerId: String,
        limit: Int? = nil,
        afterId: String = "",
        totemIds: [String]? = nil
    ) async -> (groups: [Seer.Group], hasMore: Bool, nextAfterId: String) {
        guard let client = _totemQueryClient as? TotemQueryClient else { return ([], false, "") }
        let allNodes = await nonisolatedRegistryMutator.activeNodes
        let nodes: [TotemNode]
        if let ids = totemIds, !ids.isEmpty {
            nodes = allNodes.filter { ids.contains($0.totemId.uuidString) }
        } else if !ownerId.isEmpty {
            nodes = await nonisolatedRegistryMutator.totemNodesForOwner(ownerId, allNodes: allNodes)
        } else {
            nodes = allNodes
        }
        guard !nodes.isEmpty else { return ([], false, "") }

        var groupMap: [String: Seer.Group] = [:]
        var hasMore = false

        if let limit {
            // Single-page fetch: one gRPC request per Totem with the caller's cursor/limit.
            await withTaskGroup(of: (groups: [Seer.Group], hasMore: Bool).self) { group in
                for node in nodes {
                    group.addTask {
                        var req = Totem_V1_TotemLibraryRequest()
                        req.ownerID          = ownerId
                        req.includeAvailable = true
                        req.limit            = Int32(limit)
                        req.afterID          = afterId
                        req.totemID          = node.totemId.uuidString
                        guard let resp = try? await client.library(req, totem: node) else { return ([], false) }
                        if !resp.groups.isEmpty && !ownerId.isEmpty {
                            await self.nonisolatedRegistryMutator.recordOwnerTotem(
                                ownerId: ownerId, totemId: node.totemId
                            )
                        }
                        return (resp.groups.map(convertTotemGroupLight), resp.hasMore_p)
                    }
                }
                for await (groups, nodeHasMore) in group {
                    hasMore = hasMore || nodeHasMore
                    mergeTotemGroups(groups, into: &groupMap)
                }
            }
        } else {
            // Full multi-page fetch: loop until each Totem reports no more pages.
            let pageSize: Int32 = 200
            await withTaskGroup(of: [Seer.Group].self) { group in
                for node in nodes {
                    group.addTask {
                        var pageGroups: [Seer.Group] = []
                        var cursor = ""
                        var recorded = false
                        repeat {
                            var req = Totem_V1_TotemLibraryRequest()
                            req.ownerID          = ownerId
                            req.includeAvailable = true
                            req.limit            = pageSize
                            req.afterID          = cursor
                            req.totemID          = node.totemId.uuidString
                            guard let resp = try? await client.library(req, totem: node) else { break }
                            if !recorded && !resp.groups.isEmpty && !ownerId.isEmpty {
                                await self.nonisolatedRegistryMutator.recordOwnerTotem(
                                    ownerId: ownerId, totemId: node.totemId
                                )
                                recorded = true
                            }
                            pageGroups.append(contentsOf: resp.groups.map(convertTotemGroup))
                            cursor = resp.groups.last?.id ?? ""
                            if !resp.hasMore_p { break }
                        } while true
                        return pageGroups
                    }
                }
                for await groups in group {
                    mergeTotemGroups(groups, into: &groupMap)
                }
            }
        }

        let sorted = Array(groupMap.values).sorted { $0.id < $1.id }
        return (sorted, hasMore, sorted.last?.id ?? "")
    }

    /// Fans out a document-ID-filtered Library request to targeted Totem nodes.
    /// Uses the Totem's reverse `documentGroups` map — no full library scan.
    /// Returns matching groups and a documentId → groupId map.
    nonisolated func fanoutLibraryByDocuments(
        ownerId: String,
        documentIds: [String],
        totemIds: [String]? = nil
    ) async -> (groups: [Seer.Group], documentGroups: [String: String]) {
        guard let client = _totemQueryClient as? TotemQueryClient else { return ([], [:]) }
        let allNodes = await nonisolatedRegistryMutator.activeNodes
        let nodes: [TotemNode]
        if let ids = totemIds, !ids.isEmpty {
            nodes = allNodes.filter { ids.contains($0.totemId.uuidString) }
        } else if !ownerId.isEmpty {
            nodes = await nonisolatedRegistryMutator.totemNodesForOwner(ownerId, allNodes: allNodes)
        } else {
            nodes = allNodes
        }
        guard !nodes.isEmpty else { return ([], [:]) }

        var groupMap: [String: Seer.Group] = [:]

        await withTaskGroup(of: [Seer.Group].self) { group in
            for node in nodes {
                group.addTask {
                    var req = Totem_V1_TotemLibraryRequest()
                    req.ownerID     = ownerId
                    req.totemID     = node.totemId.uuidString
                    req.documentIds = documentIds
                    guard let resp = try? await client.library(req, totem: node) else { return [] }
                    return resp.groups.map(convertTotemGroup)
                }
            }
            for await groups in group {
                mergeTotemGroups(groups, into: &groupMap)
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

extension Seer {
    /// Fans out a knowledge-graph query to all active Totem nodes and merges the
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
    ) async -> Totem_V1_TotemGraphQueryResponse {
        var merged = Totem_V1_TotemGraphQueryResponse()
        guard let client = _totemQueryClient as? TotemQueryClient else { return merged }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return merged }

        var req = Totem_V1_TotemGraphQueryRequest()
        req.ownerID = ownerId
        req.entity = entity ?? ""
        req.query = query ?? ""
        req.kinds = kinds
        req.hops = Int32(hops)
        req.limit = Int32(limit)
        req.includeDocuments = includeDocuments

        let responses = await withTaskGroup(of: Totem_V1_TotemGraphQueryResponse?.self) { group in
            for node in nodes {
                group.addTask {
                    try? await client.graph(req, totem: node)
                }
            }
            var all: [Totem_V1_TotemGraphQueryResponse] = []
            for await response in group {
                if let response { all.append(response) }
            }
            return all
        }

        var entitiesById: [String: Totem_V1_TotemGraphEntity] = [:]
        var relationshipsById: [String: Totem_V1_TotemGraphRelationship] = [:]
        var documentsById: [String: Totem_V1_TotemGraphDocument] = [:]
        var stats = Totem_V1_TotemGraphStats()

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

extension Seer {
    /// Broadcasts a group access/label/metadata update to all active Totem nodes.
    /// Returns true if at least one Totem confirmed success.
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
        guard let client = _totemQueryClient as? TotemQueryClient else { return false }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return false }

        var req = Totem_V1_TotemUpdateGroupRequest()
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
                    (try? await client.updateGroup(req, totem: node))?.success ?? false
                }
            }
            var anySuccess = false
            for await success in group { anySuccess = anySuccess || success }
            return anySuccess
        }
    }

    /// Broadcasts a document access/group update to all active Totem nodes.
    /// Returns true if at least one Totem confirmed success.
    @discardableResult
    nonisolated func fanoutUpdateDocument(
        documentId: String,
        ownerId: String,
        access: String?,
        groupId: String?
    ) async -> Bool {
        guard let client = _totemQueryClient as? TotemQueryClient else { return false }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return false }

        var req = Totem_V1_TotemUpdateDocumentRequest()
        req.ownerID = ownerId
        req.documentID = documentId
        if let access { req.access = access }
        if let groupId { req.groupID = groupId }

        return await withTaskGroup(of: Bool.self) { group in
            for node in nodes {
                group.addTask {
                    (try? await client.updateDocument(req, totem: node))?.success ?? false
                }
            }
            var anySuccess = false
            for await success in group { anySuccess = anySuccess || success }
            return anySuccess
        }
    }

    /// Fetches registry stats from all active Totem nodes in parallel.
    /// Returns a map of totemId (UUID string) → stats response.
    nonisolated func fanoutStats() async -> [String: Totem_V1_TotemStatsResponse] {
        guard let client = _totemQueryClient as? TotemQueryClient else { return [:] }
        let nodes = await nonisolatedRegistryMutator.activeNodes
        guard !nodes.isEmpty else { return [:] }

        let req = Totem_V1_TotemStatsRequest()
        return await withTaskGroup(of: (String, Totem_V1_TotemStatsResponse?).self) { group in
            for node in nodes {
                group.addTask {
                    let resp = try? await client.stats(req, totem: node)
                    return (node.totemId.uuidString, resp)
                }
            }
            var result: [String: Totem_V1_TotemStatsResponse] = [:]
            for await (totemId, resp) in group {
                if let resp { result[totemId] = resp }
            }
            return result
        }
    }
}

// MARK: - Private helpers

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
