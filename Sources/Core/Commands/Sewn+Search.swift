//
//  Sewn+Search.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Metrics


extension Sewn {
    /// Search via connected Thread nodes. Passes the raw query text; each Thread
    /// embeds it locally before searching its HNSW index.
    nonisolated func search(_ query: String?,
                request: SewnRequest,
                topK: Int = 3,
                enableSinatraPark: Bool = true) async throws -> SearchChatResult {
        guard let query, !query.isEmpty else {
            logger.info("Search", "No query to search.", service: .sewn, request: request, flow: .chat)
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        if _threadQueryClient != nil {
            return try await searchWithThreads(query, request: request, topK: topK)
        }

        logger.warning("No Thread client connected — returning empty result.", service: .sewn, request: request)
        return SearchChatResult(context: [], adjustments: [], references: [])
    }
}

// MARK: - High-level chat search with Thread fan-out

extension Sewn {
    nonisolated func searchWithThreads(
        _ query: String?,
        request: SewnRequest,
        topK: Int = 3
    ) async throws -> SearchChatResult {
        guard let query, !query.isEmpty else {
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        let (threadResults, protoTrace) = await fanoutSearch(
            queryText: query,
            request: request,
            topK: topK
        )

        var scoreMap: [String: Float] = [:]
        var peerSources: [String: OracleNodeID] = [:]
        var threadMeta: [String: String] = [:]   // partitionId → threadId

        let rawPartitions: [Sewn.Partition] = threadResults.map { result in
            scoreMap[result.partitionID] = result.score
            threadMeta[result.partitionID] = result.threadID
            if let tid = UUID(uuidString: result.threadID) {
                peerSources[result.partitionID] = tid
            }
            return Sewn.Partition(
                id: result.partitionID,
                documentId: result.documentID,
                url: URL(string: "thread://\(result.threadID)")!,
                embedding: [],
                text: result.text,
                ownerId: result.ownerID
            )
        }

        var seen = Set<String>()
        let partitions = rawPartitions.filter { seen.insert($0.id).inserted }

        let scoredPartitions: [(score: Float, partition: Sewn.Partition)] = partitions.compactMap { p in
            guard let s = scoreMap[p.id] else { return nil }
            return (s, p)
        }
        sinatra.park(data: scoredPartitions, forQuery: [], request: request)

        // Derive co-owners from partition results: group by documentId, collect unique ownerIds.
        // Thread is the source of truth — no SewnRegistry read needed.
        var coOwnerMap: [DocumentID: Set<OwnerID>] = [:]
        for p in partitions {
            guard !p.ownerId.isEmpty else { continue }
            coOwnerMap[p.documentId, default: []].insert(p.ownerId)
        }
        let derivedCoOwners = coOwnerMap.filter { $0.value.count > 1 }

        let gitaResult = gita.track(
            Gita.Payload(
                partitions: partitions,
                peerSources: peerSources,
                coOwners: derivedCoOwners
            ),
            command: .inference,
            request: request
        )

        let references: [Sewn.DocumentReference] = partitions.map { p in
            .init(id: p.documentId, partitionId: p.id, ownerId: p.ownerId,
                  threadId: threadMeta[p.id])
        }

        let trace: Sewn.GraphTrace? = protoTrace.map {
            Sewn.GraphTrace(
                matchedEntityIds: $0.matchedEntityIds,
                expansionEdgeIds: $0.expansionEdgeIds,
                expandedDocuments: Int($0.expandedDocumentCount)
            )
        }

        return SearchChatResult(
            context: partitions.map(\.text),
            adjustments: [],
            references: references,
            contribution: gitaResult.contribution,
            partitions: partitions,
            trace: trace,
            retrieved: Sewn.RetrievedPartition.from(partitions, scores: scoreMap)
        )
    }
}
