//
//  Sinatra+Park.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 1/25/26.
//

import Foundation
import Metrics

extension Sinatra {
    /// Park searched partitions for training when future chat messages appear. Past
    /// search results are retrieved to create a dataSet updating Sinatra.
    /// - Parameters:
    ///   - data: The last partition search result for a context-engineered response.
    ///   - embedding: The embeddings of the query.
    func park(data: [(score: Float, partition: Sewn.Partition)],
              forQuery embedding: [Float],
              request: SewnRequest) {

        let owner: SewnRegistry.Owner = .init(id: request.ownerId)
        // logger.debug("Park", "⚜️ Starting park for owner: \(owner.id), partitionResults: \(data.count), queryEmbeddingDim: \(embedding.count)", service: .sinatra, request: request)

        // Compile into `SinatraDataSet`
        let dataSets: [SinatraTrainingData.Parked] = data.map { (score, partition) in
            SinatraTrainingData.Parked(
                id: partition.id,
                documentId: partition.documentId,
                partitionCompressedEmbedding: partition.compressedEmbedding,
                distance: score
            )
        }

        // for item in dataSets {
        //     logger.debug("Park", "⚜️ Parked partition=\(item.id), distance=\(item.distance)", service: .sinatra, request: request)
        // }

        var existingCount = 0
        var newCount = 0
        updateRegistry { registry in
            existingCount = registry.parked[owner]?.count ?? 0
            // Fix: use `default: []` so the first park call doesn't double-store dataSets.
            // `default: dataSets` would insert dataSets as the default then append dataSets
            // again, storing every initial batch twice.
            registry.parked[owner, default: []].append(contentsOf: dataSets)
            // Rolling window: drop the oldest entries when the cap is exceeded.
            // Prevents the DEFER path (ambiguous+low-confidence sentiment) from
            // accumulating parked data indefinitely across many turns.
            if let count = registry.parked[owner]?.count, count > Sinatra.maxParkedEntries {
                let excess = count - Sinatra.maxParkedEntries
                registry.parked[owner] = Array(registry.parked[owner]!.dropFirst(excess))
            }
            newCount = registry.parked[owner]?.count ?? 0
        }
        // logger.debug("Park", "⚜️ Registry saved", service: .sinatra, request: request)

        SewnMetrics.sinatraParked.record(Double(newCount))

        let distanceRange = dataSets.map(\.distance).sorted()
        let minDist = distanceRange.first.map { String(format: "%.4f", $0) } ?? "n/a"
        let maxDist = distanceRange.last.map { String(format: "%.4f", $0) } ?? "n/a"
        logger.debug("Park", "⚜️ owner=\(owner.id) | parked \(dataSets.count) partitions (dist \(minDist)–\(maxDist)) | registry \(existingCount)→\(newCount)", service: .parking, request: request)

        // Frank flow: one info log per partition so each content unit's retrieval
        // event is correlated with its later training and inference events in Cockpit.
        for item in dataSets {
            logger.info("Park", "⚜️ [PARK] partition=\(item.id) doc=\(item.documentId) dist=\(String(format: "%.4f", item.distance))",
                        service: .parking, request: request, flow: .frank(partitionId: item.id))
        }
    }

    /// Park document-level tag filter results for adaptive threshold learning.
    /// Called once per search after the tag pre-filter runs.
    /// Rolling window: same `maxParkedEntries` cap as partition-level parking.
    func parkIndices(
        data: [(documentId: DocumentID, tagDistance: Float?, wasIncluded: Bool)],
        request: SewnRequest
    ) {
        guard !data.isEmpty else { return }
        let owner = SewnRegistry.Owner(id: request.ownerId)
        let entries = data.map {
            SinatraTrainingData.ParkedIndex(
                documentId: $0.documentId,
                tagDistance: $0.tagDistance,
                wasIncluded: $0.wasIncluded
            )
        }

        var existingCount = 0
        var newCount = 0
        updateRegistry { registry in
            existingCount = registry.parkedIndices[owner]?.count ?? 0
            registry.parkedIndices[owner, default: []].append(contentsOf: entries)
            if let count = registry.parkedIndices[owner]?.count, count > Sinatra.maxParkedEntries {
                let excess = count - Sinatra.maxParkedEntries
                registry.parkedIndices[owner] = Array(registry.parkedIndices[owner]!.dropFirst(excess))
            }
            newCount = registry.parkedIndices[owner]?.count ?? 0
        }

        let included = entries.filter(\.wasIncluded).count
        let excluded = entries.count - included
        logger.debug(
            "ParkIndices",
            "⚜️ owner=\(owner.id) | indices \(included) included / \(excluded) excluded | registry \(existingCount)→\(newCount)",
            service: .parking, request: request
        )

        for item in entries {
            let distStr = item.tagDistance.map { String(format: "%.4f", $0) } ?? "untagged"
            logger.info(
                "ParkIndices",
                "⚜️ [PARK-IDX] doc=\(item.documentId) tagDist=\(distStr) included=\(item.wasIncluded)",
                service: .parking, request: request
            )
        }
    }
}
