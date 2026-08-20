//
//  Seer+Search.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Metrics


extension Seer {
    /// Search via connected Totem nodes. Passes the raw query text; each Totem
    /// embeds it locally before searching its HNSW index.
    nonisolated func search(_ query: String?,
                request: SeerRequest,
                topK: Int = 3,
                enableSinatraPark: Bool = true) async throws -> SearchChatResult {
        guard let query, !query.isEmpty else {
            logger.info("Search", "No query to search.", service: .seer, request: request, flow: .chat)
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        if _totemQueryClient != nil {
            return try await searchWithTotems(query, request: request, topK: topK)
        }

        logger.warning("No Totem client connected — returning empty result.", service: .seer, request: request)
        return SearchChatResult(context: [], adjustments: [], references: [])
    }
}

// MARK: - High-level chat search with Totem fan-out

extension Seer {
    nonisolated func searchWithTotems(
        _ query: String?,
        request: SeerRequest,
        topK: Int = 3
    ) async throws -> SearchChatResult {
        guard let query, !query.isEmpty else {
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        let (totemResults, protoTrace) = await fanoutSearch(
            queryText: query,
            request: request,
            topK: topK
        )

        var scoreMap: [String: Float] = [:]
        var peerSources: [String: OracleNodeID] = [:]
        var totemMeta: [String: String] = [:]   // partitionId → totemId

        let rawPartitions: [Seer.Partition] = totemResults.map { result in
            scoreMap[result.partitionID] = result.score
            totemMeta[result.partitionID] = result.totemID
            if let tid = UUID(uuidString: result.totemID) {
                peerSources[result.partitionID] = tid
            }
            return Seer.Partition(
                id: result.partitionID,
                documentId: result.documentID,
                url: URL(string: "totem://\(result.totemID)")!,
                embedding: [],
                text: result.text,
                ownerId: result.ownerID
            )
        }

        var seen = Set<String>()
        let partitions = rawPartitions.filter { seen.insert($0.id).inserted }

        let scoredPartitions: [(score: Float, partition: Seer.Partition)] = partitions.compactMap { p in
            guard let s = scoreMap[p.id] else { return nil }
            return (s, p)
        }
        sinatra.park(data: scoredPartitions, forQuery: [], request: request)

        // Derive co-owners from partition results: group by documentId, collect unique ownerIds.
        // Totem is the source of truth — no SeerRegistry read needed.
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

        let references: [Seer.DocumentReference] = partitions.map { p in
            .init(id: p.documentId, partitionId: p.id, ownerId: p.ownerId,
                  totemId: totemMeta[p.id])
        }

        let trace: Seer.GraphTrace? = protoTrace.map {
            Seer.GraphTrace(
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
            trace: trace
        )
    }
}
