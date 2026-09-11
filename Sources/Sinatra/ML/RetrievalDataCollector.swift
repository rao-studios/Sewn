//
//  RetrievalDataCollector.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/8/26.
//

import Foundation
import Logging

// === DATA COLLECTION SYSTEM ===

struct RetrievalDataCollector: Codable {
    /// The number of tunable indicator features — equals `IndicatorPeriods.bounds.count`.
    /// IMBHS optimises exactly this many dimensions; adding a new indicator requires
    /// updating `IndicatorPeriods` and this value will follow automatically.
    static let indicatorCount: Int = IndicatorPeriods.bounds.count

    /// Total feature-vector width: all indicator features + docStats.averageSentiment
    /// + paceScore + attentivenessScore appended by `generateFeatureVector`.
    static let featureVectorDimension: Int = indicatorCount + 3

    /// Minimum number of training samples required before GBT training begins.
    /// Pinned independently of `featureVectorDimension` so that adding non-indicator
    /// features to the vector (e.g. `docStats.averageSentiment`) does not delay training.
    ///
    /// At n < ~13, `GBTHyperparameters.adaptive` (minChildWeight=5, subsample=0.8)
    /// means all trees degenerate to single-leaf (mean) predictors — still a valid
    /// prior. Meaningful splits emerge around n=13. Setting the floor low lets the
    /// model bootstrap as a mean estimator and transition to real trees naturally.
    static let minimumTrainingSamples: Int = 5

    /// Maximum number of interaction records retained.
    /// Indicators look back at most 20; 200 gives ~67 chat turns of headroom.
    static let interactionHistoryLimit: Int = 200

    /// Maximum number of MACD history entries retained.
    /// Indicators look back at most 10; 100 is generous.
    static let macdHistoryLimit: Int = 100

    private var interactionHistory: [InteractionRecord] = []
    private var macdHistory: [Double] = []

    var interactionHistoryCount: Int { interactionHistory.count }

    /// Returns the most recent `limit` interaction records, oldest first.
    /// Used by the /v1/frank/parking debug route.
    func recentInteractions(limit: Int = 20) -> [InteractionRecord] {
        return Array(interactionHistory.suffix(limit))
    }

    // Lifetime interval tracking for avgVolChange historical baseline.
    // Maintained across compactions so trimming interactionHistory
    // doesn't shift the historical average.
    private var lifetimeIntervalSum: Double = 0
    private var lifetimeIntervalCount: Int = 0

    // Active indicator period configuration. Tuned at runtime by HarmonyMemory.
    // Decodes with fallback to .default for backward compatibility.
    var periods: IndicatorPeriods = .default

    /// Transient logger — excluded from Codable. Must be set after decoding.
    var logger: SewnLogger?

    enum CodingKeys: String, CodingKey {
        case interactionHistory
        case macdHistory
        case lifetimeIntervalSum
        case lifetimeIntervalCount
        case periods
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interactionHistory    = try container.decode([InteractionRecord].self, forKey: .interactionHistory)
        macdHistory           = try container.decode([Double].self, forKey: .macdHistory)
        lifetimeIntervalSum   = try container.decodeIfPresent(Double.self, forKey: .lifetimeIntervalSum) ?? 0
        lifetimeIntervalCount = try container.decodeIfPresent(Int.self, forKey: .lifetimeIntervalCount) ?? 0
        periods               = try container.decodeIfPresent(IndicatorPeriods.self, forKey: .periods) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interactionHistory,    forKey: .interactionHistory)
        try container.encode(macdHistory,           forKey: .macdHistory)
        try container.encode(lifetimeIntervalSum,   forKey: .lifetimeIntervalSum)
        try container.encode(lifetimeIntervalCount, forKey: .lifetimeIntervalCount)
        try container.encode(periods,               forKey: .periods)
    }

    /// Records an interaction and returns the updated `Sewn.DocumentStats` for the
    /// given partition. The caller is responsible for persisting the returned entry
    /// back to `SewnRegistry.documentStats` via `RegistryMutator.accumulatePerformance`.
    ///
    /// - Parameters:
    ///   - existingStats: The current `DocumentStats` from the registry snapshot, if any.
    ///                    When `nil`, a zero-value entry is created for the partition.
    @discardableResult
    mutating func recordInteraction(
        parked: SinatraTrainingData.Parked,
        sentiment: Sinatra.Sentiment,
        responseLength: Int,
        effectiveWeight: Double? = nil,
        paceScore: Double = 0.5,
        attentivenessScore: Double = 0.0,
        existingStats: Sewn.DocumentStats? = nil,
        request: SewnRequest? = nil
    ) -> Sewn.DocumentStats {
        let partitionId = parked.id
        let docId       = parked.documentId.isEmpty ? parked.id : parked.documentId
        let weight      = effectiveWeight ?? sentiment.calculateWeight()

        let record = InteractionRecord(
            timestamp: Date(),
            sentimentWeight: weight,
            responseLength: responseLength,
            id: partitionId,
            documentId: docId,
            paceScore: paceScore,
            attentivenessScore: attentivenessScore
        )

        // Track lifetime interval before appending (need previous timestamp)
        if let previous = interactionHistory.last {
            let interval = record.timestamp.timeIntervalSince(previous.timestamp)
            lifetimeIntervalSum  += interval
            lifetimeIntervalCount += 1
        }

        interactionHistory.append(record)

        // Update MACD history using active period parameters.
        // Minimum: history must reach periods.macdSlow before MACD is meaningful.
        if interactionHistory.count >= periods.macdSlow {
            let indicators = TechnicalIndicators(history: interactionHistory)
            let macd = indicators.macD(fastPeriod: periods.macdFast, slowPeriod: periods.macdSlow)
            macdHistory.append(macd)
        }

        compact(request: request)

        // Build the updated document performance entry and return it to the caller.
        // Use docId (document ID) as the stats key; bump partitionRetrievalCount
        // and partitionSentiments with the specific partitionId for per-partition granularity.
        var stats = existingStats ?? Sewn.DocumentStats(id: docId)
        stats.retrievalCount += 1
        stats.sentimentSum   += weight
        stats.lastRetrieved  = Date()
        stats.partitionRetrievalCount[partitionId, default: 0] += 1
        // Accumulate per-partition sentiment so the GBT feature vector reflects
        // engagement with this specific content unit rather than the document as a whole.
        stats.partitionSentiments[partitionId, default: .init()].retrievalCount += 1
        stats.partitionSentiments[partitionId, default: .init()].sentimentSum   += weight
        stats.partitionSentiments[partitionId, default: .init()].lastRetrieved  = Date()
        return stats
    }

    // MARK: - Feature Vector Generation

    /// Generate a feature vector for a partition against the current interaction history.
    /// Used by both the training path and the inference path — single source of truth for the
    /// feature layout so both paths stay in sync automatically.
    ///
    /// - Parameters:
    ///   - partitionId: Content-addressed partition ID (SHA-256 of embedding). Used to look up
    ///                  per-partition sentiment for the `avg_sentiment` feature.
    ///   - documentId:  Document the partition belongs to. Used to route to the correct
    ///                  `DocumentStats` entry in `documentStats`.
    ///   - documentStats: Registry snapshot keyed by document ID. Pass the caller's local
    ///                    accumulation so vectors reflect updates from the current cycle.
    func generateFeatureVector(
        partitionId: String,
        documentId: String = "",
        documentStats: [DocumentID: Sewn.DocumentStats] = [:],
        request: SewnRequest? = nil
    ) -> [Double]? {
        guard interactionHistory.count >= 20 else {
            return nil
        }

        let indicators    = TechnicalIndicators(history: interactionHistory)
        let partSentiment = documentStats[documentId]?.partitionSentiments[partitionId]
        let p             = periods

        let emaWA              = indicators.emaWA(period: p.emaPeriod)
        let smaWA              = indicators.smaWA(period: p.smaPeriod)
        let macd               = indicators.macD(fastPeriod: p.macdFast, slowPeriod: p.macdSlow)
        let macdSignal         = indicators.macDSignal(macdHistory: macdHistory, signalPeriod: p.macdSignalPeriod)
        let macdPreviousSignal = indicators.macDPreviousSignal(macdHistory: macdHistory)
        let avgVolChange       = indicators.avgVolChange(period: p.avgVolPeriod, lifetimeAvgInterval: lifetimeAvgInterval)
        let vwa                = indicators.volumeWeightedAverage(period: p.vwaPeriod)
        let stochasticK        = indicators.stochasticK(period: p.stochKPeriod)
        let stochasticD        = indicators.stochasticD(period: p.stochKPeriod, signalPeriod: p.stochDSignal)
        let mom                = indicators.momentum(period: p.momentumPeriod)
        let vel                = indicators.velocity(period: p.velocityPeriod)

        // Pace and attentiveness reflect the engagement context of the most recent
        // interaction. At training time that is the record just appended; at
        // inference time it is the last known interaction before the new turn.
        let pace      = interactionHistory.last?.paceScore         ?? 0.5
        let attentive = interactionHistory.last?.attentivenessScore ?? 0.0

        return [
            emaWA,                          // Level: fast sentiment trend
            smaWA,                          // Level: slow sentiment baseline
            macd,                           // EMA-Momentum: current
            macdSignal,                     // EMA-Momentum: signal line
            macdPreviousSignal,             // EMA-Momentum: previous signal (crossover)
            avgVolChange,                   // Volume: interaction frequency change
            vwa,                            // Volume: response-length-weighted sentiment
            stochasticK,                    // Oscillator: range position
            stochasticD,                    // Oscillator: smoothed range position
            mom,                            // Raw differential: 1st derivative
            vel,                            // Raw differential: 2nd derivative
            partSentiment?.averageSentiment ?? 0.5, // Per-partition: historical sentiment
            pace,                           // Engagement: pace score of current interaction
            attentive,                      // Engagement: attentiveness score of current interaction
        ]
    }

    // MARK: - IMBHS Support

    /// Evaluate the fitness (leave-recent-out MAE) of a candidate `IndicatorPeriods`
    /// against the current GBTModel. Lower MAE = better fitness.
    ///
    /// Walks `interactionHistory`, recomputes feature vectors with `candidatePeriods`,
    /// calls `model.predictOne` for each, and returns mean absolute error.
    /// O(n · T · depth) — no retraining required.
    ///
    /// - Parameter documentStats: Registry snapshot used to look up `averageSentiment`
    ///                            per partition. Pass the caller's local accumulation.
    func evaluateFitness(
        periods candidatePeriods: IndicatorPeriods,
        model: GBTModel,
        documentStats: [DocumentID: Sewn.DocumentStats] = [:]
    ) -> Double {
        guard interactionHistory.count >= 20 else { return .infinity }

        // Build temp MACD history for candidate periods
        let tempMACDHistory = buildTempMACDHistory(for: candidatePeriods)

        var errors = [Double]()
        for i in 0..<interactionHistory.count {
            guard i + 1 >= 20 else { continue }
            let subHistory = Array(interactionHistory.prefix(i + 1))
            let record     = interactionHistory[i]
            let indicators = TechnicalIndicators(history: subHistory)
            let docKey      = record.documentId.isEmpty ? record.id : record.documentId
            let partSentiment = documentStats[docKey]?.partitionSentiments[record.id]
            let cp          = candidatePeriods

            // MACD history slice up to this interaction
            let macdCount = i >= cp.macdSlow - 1 ? i - cp.macdSlow + 2 : 0
            let macdSlice = Array(tempMACDHistory.prefix(macdCount))

            let features: [Double] = [
                indicators.emaWA(period: cp.emaPeriod),
                indicators.smaWA(period: cp.smaPeriod),
                indicators.macD(fastPeriod: cp.macdFast, slowPeriod: cp.macdSlow),
                indicators.macDSignal(macdHistory: macdSlice, signalPeriod: cp.macdSignalPeriod),
                indicators.macDPreviousSignal(macdHistory: macdSlice),
                indicators.avgVolChange(period: cp.avgVolPeriod, lifetimeAvgInterval: lifetimeAvgInterval),
                indicators.volumeWeightedAverage(period: cp.vwaPeriod),
                indicators.stochasticK(period: cp.stochKPeriod),
                indicators.stochasticD(period: cp.stochKPeriod, signalPeriod: cp.stochDSignal),
                indicators.momentum(period: cp.momentumPeriod),
                indicators.velocity(period: cp.velocityPeriod),
                partSentiment?.averageSentiment ?? 0.5,
                interactionHistory[i].paceScore,
                interactionHistory[i].attentivenessScore,
            ]

            let predicted = model.predictOne(inputs: features)
            errors.append(abs(predicted - record.sentimentWeight))
        }

        guard !errors.isEmpty else { return .infinity }
        return errors.reduce(0, +) / Double(errors.count)
    }

    /// Apply new period settings: updates `self.periods` and rebuilds
    /// `macdHistory` consistently with the new `macdFast`/`macdSlow`.
    /// Called by `Sinatra+Sentiment` when `HarmonyMemory.activePeriods` changes.
    mutating func applyPeriods(_ newPeriods: IndicatorPeriods) {
        periods     = newPeriods
        macdHistory = buildTempMACDHistory(for: newPeriods)

        // Compact to limit
        if macdHistory.count > Self.macdHistoryLimit {
            let excess = macdHistory.count - Self.macdHistoryLimit
            macdHistory.removeFirst(excess)
        }
    }

    /// Rebuild a complete training `DataSet` from `interactionHistory`
    /// using the current `self.periods`. Called after `applyPeriods` to
    /// recreate training data on the new feature space before retraining.
    ///
    /// - Parameter documentStats: Registry snapshot used to look up `averageSentiment`
    ///                            per partition. Pass the caller's local accumulation.
    func buildDataSet(documentStats: [DocumentID: Sewn.DocumentStats] = [:]) -> DataSet {
        var dataSet = DataSet(
            dataType: .Regression,
            inputDimension: Self.featureVectorDimension,
            outputDimension: 1
        )

        let p               = periods
        let tempMACDHistory = buildTempMACDHistory(for: p)

        for i in 0..<interactionHistory.count {
            guard i + 1 >= 20 else { continue }
            let subHistory = Array(interactionHistory.prefix(i + 1))
            let record     = interactionHistory[i]
            let indicators = TechnicalIndicators(history: subHistory)
            let docKey        = record.documentId.isEmpty ? record.id : record.documentId
            let partSentiment = documentStats[docKey]?.partitionSentiments[record.id]

            let macdCount = i >= p.macdSlow - 1 ? i - p.macdSlow + 2 : 0
            let macdSlice = Array(tempMACDHistory.prefix(macdCount))

            let features: [Double] = [
                indicators.emaWA(period: p.emaPeriod),
                indicators.smaWA(period: p.smaPeriod),
                indicators.macD(fastPeriod: p.macdFast, slowPeriod: p.macdSlow),
                indicators.macDSignal(macdHistory: macdSlice, signalPeriod: p.macdSignalPeriod),
                indicators.macDPreviousSignal(macdHistory: macdSlice),
                indicators.avgVolChange(period: p.avgVolPeriod, lifetimeAvgInterval: lifetimeAvgInterval),
                indicators.volumeWeightedAverage(period: p.vwaPeriod),
                indicators.stochasticK(period: p.stochKPeriod),
                indicators.stochasticD(period: p.stochKPeriod, signalPeriod: p.stochDSignal),
                indicators.momentum(period: p.momentumPeriod),
                indicators.velocity(period: p.velocityPeriod),
                partSentiment?.averageSentiment ?? 0.5,
                record.paceScore,
                record.attentivenessScore,
            ]

            try? dataSet.addDataPoint(
                input: features,
                output: [record.sentimentWeight],
                label: record.id
            )
        }

        return dataSet
    }

    // MARK: - Private helpers

    /// Lifetime average interval between interactions, maintained across
    /// compactions so trimming interactionHistory doesn't shift the baseline.
    var lifetimeAvgInterval: Double? {
        guard lifetimeIntervalCount > 0 else { return nil }
        return lifetimeIntervalSum / Double(lifetimeIntervalCount)
    }

    /// Reconstruct a MACD history array for a given period configuration
    /// by walking the current `interactionHistory` from the beginning.
    /// Used by both `evaluateFitness` and `applyPeriods`.
    private func buildTempMACDHistory(for p: IndicatorPeriods) -> [Double] {
        var result = [Double]()
        for i in 0..<interactionHistory.count {
            let subHistory = Array(interactionHistory.prefix(i + 1))
            guard subHistory.count >= p.macdSlow else { continue }
            let indicators = TechnicalIndicators(history: subHistory)
            result.append(indicators.macD(fastPeriod: p.macdFast, slowPeriod: p.macdSlow))
        }
        return result
    }

    // MARK: - Compaction

    /// Trims unbounded data structures to prevent registry bloat.
    private mutating func compact(request: SewnRequest? = nil) {
        var trimmed = false

        if interactionHistory.count > Self.interactionHistoryLimit {
            let excess = interactionHistory.count - Self.interactionHistoryLimit
            interactionHistory.removeFirst(excess)
            trimmed = true
        }

        if macdHistory.count > Self.macdHistoryLimit {
            let excess = macdHistory.count - Self.macdHistoryLimit
            macdHistory.removeFirst(excess)
            trimmed = true
        }

        if trimmed {
            logger?.debug("Compact", "⚜️ history=\(interactionHistory.count), macd=\(macdHistory.count)", service: .sinatra, request: request)
        }
    }
}
