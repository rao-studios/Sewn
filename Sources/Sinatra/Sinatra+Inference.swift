//
//  Sinatra+Inference.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 1/25/26.
//

import Foundation
import Metrics

extension Sinatra {
    /// Using the trained GBT model and the owner's RetrievalDataCollector,
    /// predict a sentiment value for the given partition and adjust its
    /// distance accordingly. Partitions predicted to have positive sentiment
    /// get a lower (better) distance, while negative sentiment increases it.
    /// - Parameters:
    ///   - inference: `SinatraInference` containing partition id and PQ distance from the current search.
    ///   - request: The current `SewnRequest` for owner lookup.
    /// - Returns: `SinatraInference.Result` with the adjusted distance.
    /// Infer with a caller-supplied registry snapshot.
    /// Use this inside search loops — load `sinatra.registry` once before the loop
    /// and pass it here to avoid a disk read per partition result.
    ///
    /// - Parameter documentStats: Snapshot of `SewnRegistry.documentStats`. Used to look up
    ///   `partitionSentiments[partitionId].averageSentiment` for the GBT feature vector so
    ///   inference reflects per-partition engagement rather than document-level averages.
    func infer(_ inference: SinatraInference,
               registry: SinatraRegistry?,
               documentStats: [DocumentID: Sewn.DocumentStats] = [:],
               request: SewnRequest) -> SinatraInference.Result {
        SewnMetrics.sinatraInferences.increment()
        let owner = SewnRegistry.Owner(id: request.ownerId)
        let distance = inference.distance

        guard let registry = registry else {
            // logger.debug("Infer", "⚜️ No registry found — returning unadjusted", service: .sinatra, request: request)
            Counter(label: "sinatra.unadjusted_total", dimensions: [("reason", "no_registry")]).increment()
            return .unadjusted(distance: distance)
        }

        guard var collector = registry.collectors[owner] else {
            // logger.debug("Infer", "⚜️ No collector for owner \(owner.id) — returning unadjusted", service: .sinatra, request: request)
            Counter(label: "sinatra.unadjusted_total", dimensions: [("reason", "no_collector")]).increment()
            return .unadjusted(distance: distance)
        }
        collector.logger = logger

        guard let gbtModel = registry.models[owner] else {
            // logger.debug("Infer", "⚜️ No GBT model for owner \(owner.id) — returning unadjusted", service: .sinatra, request: request)
            Counter(label: "sinatra.unadjusted_total", dimensions: [("reason", "no_model")]).increment()
            return .unadjusted(distance: distance)
        }

        guard gbtModel.totalTrees > 0 else {
            // logger.debug("Infer", "⚜️ GBT model has 0 trees — returning unadjusted", service: .sinatra, request: request)
            Counter(label: "sinatra.unadjusted_total", dimensions: [("reason", "empty_model")]).increment()
            return .unadjusted(distance: distance)
        }

        // logger.debug("Infer", "⚜️ GBT model ready: \(gbtModel.totalTrees) trees", service: .sinatra, request: request)

        // Generate feature vector using the partition's own sentiment history.
        // partitionId addresses the specific content unit; documentId routes to
        // the correct DocumentStats entry holding partitionSentiments.
        guard let featureVector = collector.generateFeatureVector(
            partitionId: inference.partitionId,
            documentId: inference.documentId,
            documentStats: documentStats,
            request: request
        ) else {
            // logger.debug("Infer", "⚜️ Could not generate feature vector for \(inference.partitionId) — returning unadjusted", service: .sinatra, request: request)
            Counter(label: "sinatra.unadjusted_total", dimensions: [("reason", "no_features")]).increment()
            return .unadjusted(distance: distance)
        }

        // logger.debug("Infer", "⚜️ Feature vector: \(featureVector.map { String(format: "%.4f", $0) })", service: .sinatra, request: request)

        // Predict sentiment weight for this partition (range ~0..1)
        let predicted = gbtModel.predictOne(inputs: featureVector)

        // Map predicted sentiment to a distance adjustment factor.
        // Neutral sentiment (0.5) = no change (factor 1.0).
        // Positive sentiment (>0.5) = reduce distance (factor < 1.0, boosting).
        // Negative sentiment (<0.5) = increase distance (factor > 1.0, deprioritizing).
        // Scale: 0.0 sentiment -> factor 1.5, 0.5 -> 1.0, 1.0 -> 0.5
        let adjustmentFactor = 1.5 - predicted
        let clampedFactor = max(0.5, min(1.5, adjustmentFactor))
        let adjustedDistance = distance * Float(clampedFactor)

        // let wasClamped = adjustmentFactor != clampedFactor
        // logger.info("Infer", "⚜️ partition=\(inference.partitionId), predicted=\(String(format: "%.4f", predicted)), rawFactor=\(String(format: "%.4f", adjustmentFactor))\(wasClamped ? " (clamped to \(String(format: "%.4f", clampedFactor)))" : ""), distance=\(distance) -> \(adjustedDistance)", service: .sinatra, request: request)

        let wasClamped = adjustmentFactor != clampedFactor
        logger.info("Infer", "⚜️ [INFER] partition=\(inference.partitionId) predicted=\(String(format: "%.4f", predicted)) factor=\(String(format: "%.4f", clampedFactor))\(wasClamped ? " (clamped from \(String(format: "%.4f", adjustmentFactor)))" : "") dist=\(String(format: "%.4f", distance)) → \(String(format: "%.4f", adjustedDistance))",
                    service: .sinatra, request: request, flow: .frank(partitionId: inference.partitionId))

        SewnMetrics.sinatraAdjustments.increment()
        SewnMetrics.sinatraAdjustmentFactor.record(clampedFactor)
        if clampedFactor < 1.0 {
            SewnMetrics.sinatraBoosts.increment()
        } else if clampedFactor > 1.0 {
            SewnMetrics.sinatraDemotions.increment()
        }
        return .init(adjustedDistance: adjustedDistance, applied: true)
    }

    /// Returns an adaptive tag distance threshold for the given document.
    ///
    /// Base: `1.0 - PartitionIndex.tagSimilarityThreshold` (0.85).
    /// Positive engagement history widens the threshold so a known-good document
    /// isn't excluded by modest tag similarity. No stats → static base.
    /// Clamped to [0.50, 0.99].
    func inferTagThreshold(
        documentId: DocumentID,
        owner: SewnRegistry.Owner,
        registry: SinatraRegistry?,
        documentStats: [DocumentID: Sewn.DocumentStats]
    ) -> Float {
        let base: Float = 0.85

        guard let stats = documentStats[documentId],
              !stats.partitionSentiments.isEmpty else {
            return base
        }

        let sentiments: [Float] = stats.partitionSentiments.values.map { Float($0.averageSentiment) }
        guard !sentiments.isEmpty else { return base }
        let avgSentiment = sentiments.reduce(0.0, +) / Float(sentiments.count)

        // Positive engagement (>0.5) → raise threshold → include doc even with weaker tag match.
        // Negative engagement (<0.5) → no change (static threshold handles irrelevance).
        let adjustment: Float = avgSentiment > 0.5 ? (avgSentiment - 0.5) * 0.30 : 0.0
        let adjusted = min(0.99, max(0.50, base + adjustment))

        if adjustment > 0 {
            logger.debug(
                "InferTagThreshold",
                "⚜️ [TAG-THRESH] doc=\(documentId) avgSentiment=\(String(format: "%.4f", avgSentiment)) base=\(String(format: "%.4f", base)) adjusted=\(String(format: "%.4f", adjusted))",
                service: .sinatra, request: nil
            )
        }

        return adjusted
    }
}
