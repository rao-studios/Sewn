//
//  SinatraRoutes.swift
//  sewn-server
//

import Foundation
import Hummingbird

/// Registers the `/v1/frank/` debug routes:
///
/// - `POST /v1/frank/reset` — wipes all Sinatra state for the requesting owner:
///   parked partitions, interaction history, dataset, GBT model, IMBHS harmony
///   memory, last sentiment result, and last search adjustment entries.
///
/// - `POST /v1/frank/gbt`  — full GBT model state for the requesting owner:
///   training status, hyperparameters, indicator periods, IMBHS harmony memory,
///   and the complete flat-array tree structure with human-readable feature names.
///
/// - `POST /v1/frank/parking`  — real-time parking pipeline snapshot:
///   pending parked partitions, recent interaction timeline with sentiment weights
///   and named feature vectors, last full sentiment breakdown, and pipeline status.
///
/// - `POST /v1/frank/export` — portable JSON snapshot of the owner's complete
///   Sinatra state. Suitable for local storage or account-to-account transfer.
///
/// - `POST /v1/frank/import` — restores a `SinatraExport` into the requesting
///   owner's slot, replacing any existing state. The `owner_id` in the export
///   payload is metadata only — the auth'd requester's ID is always applied.
func registerFrankRoutes(_ router: some RouterMethods<SewnRequestContext>, _ sewn: Sewn) {

    // MARK: POST /v1/frank/gbt

    router.post("/v1/frank/gbt") { request, context async throws -> FrankGBTResponse in
        let body    = try await request.decode(as: FrankGBTRequest.self, context: context)
        let sewnReq = try body.sewn.from(context)
        let owner   = SewnRegistry.Owner(id: sewnReq.ownerId)

        let sinatra      = sewn.sinatra
        let registry     = sinatra.registry
        let model        = registry?.models[owner]
        let collector    = registry?.collectors[owner]
        let dataSet      = registry?.dataSets[owner]
        let harmonyMem   = registry?.harmonyMemories[owner]
        let parkedCount  = registry?.parked[owner]?.count ?? 0

        let featureNames: [String] = [
            "ema_wa", "sma_wa",
            "macd", "macd_signal", "macd_prev_signal",
            "avg_vol_change", "volume_weighted_avg",
            "stochastic_k", "stochastic_d",
            "momentum", "velocity",
            "avg_sentiment",
            "pace",
            "attentiveness",
        ]

        let hyperparameters = GBTHyperparametersView(
            from: model?.hyperparameters ?? GBTHyperparameters()
        )
        let indicatorPeriods = IndicatorPeriodsView(
            from: collector?.periods ?? .default
        )
        let harmonyMemoryView = harmonyMem.map { HarmonyMemoryView(from: $0) }

        let trees: [GBTTreeView] = (model?.trees ?? []).enumerated().map {
            GBTTreeView(index: $0.offset, tree: $0.element, featureNames: featureNames)
        }

        return FrankGBTResponse(
            isTrained:               model?.totalTrees ?? 0 > 0,
            totalTrees:              model?.totalTrees ?? 0,
            initialPrediction:       model?.initialPrediction ?? 0.5,
            peakDataSetSize:         model?.peakDataSetSize ?? 0,
            dataSetSize:             dataSet?.size ?? 0,
            minimumTrainingSamples:  RetrievalDataCollector.minimumTrainingSamples,
            interactionHistoryCount: collector?.interactionHistoryCount ?? 0,
            parkedCount:             parkedCount,
            featureNames:            featureNames,
            hyperparameters:         hyperparameters,
            indicatorPeriods:        indicatorPeriods,
            harmonyMemory:           harmonyMemoryView,
            trees:                   trees
        )
    }

    // MARK: POST /v1/frank/parking

    router.post("/v1/frank/parking") { request, context async throws -> FrankParkingResponse in
        let body    = try await request.decode(as: FrankGBTRequest.self, context: context)
        let sewnReq = try body.sewn.from(context)
        let owner   = SewnRegistry.Owner(id: sewnReq.ownerId)

        let sinatra           = sewn.sinatra
        let registry          = sinatra.registry
        let parked            = registry?.parked[owner] ?? []
        let collector         = registry?.collectors[owner]
        let model             = registry?.models[owner]
        let dataSet           = registry?.dataSets[owner]
        let harmonyMem        = registry?.harmonyMemories[owner]
        let lastSentiment     = registry?.lastSentiments[owner]
        let lastSearchEntries = registry?.lastSearchEntries[owner] ?? []
        let lastTrajectory    = registry?.lastTrajectories[owner]
        let documentStats     = sewn.registry?.documentStats ?? [:]

        let featureNames: [String] = [
            "ema_wa", "sma_wa",
            "macd", "macd_signal", "macd_prev_signal",
            "avg_vol_change", "volume_weighted_avg",
            "stochastic_k", "stochastic_d",
            "momentum", "velocity",
            "avg_sentiment",
            "pace",
            "attentiveness",
        ]

        // Pending parked items — include GBT prediction if model is trained and
        // history is deep enough for feature vector generation (>= 20 interactions).
        let isTrained = (model?.totalTrees ?? 0) > 0
        let pendingParked = parked.map { item -> PendingParkedView in
            var prediction: Double? = nil
            let docKey = item.documentId.isEmpty ? item.id : item.documentId
            if isTrained, let c = collector, let m = model,
               let vec = c.generateFeatureVector(partitionId: item.id, documentId: docKey, documentStats: documentStats) {
                prediction = m.predictOne(inputs: vec)
            }
            return PendingParkedView(from: item, predictedScore: prediction)
        }

        // Recent interactions — keyed by partition ID for Sinatra's partition-based ML.
        let recentHistory = collector?.recentInteractions(limit: 20) ?? []
        var vectorsByPartition: [String: [Double]] = [:]
        if let c = collector {
            for record in recentHistory {
                let docKey = record.documentId.isEmpty ? record.id : record.documentId
                if vectorsByPartition[record.id] == nil,
                   let vec = c.generateFeatureVector(partitionId: record.id, documentId: docKey, documentStats: documentStats) {
                    vectorsByPartition[record.id] = vec
                }
            }
        }
        let interactionEvents = recentHistory.map { record -> InteractionEventView in
            let vec = vectorsByPartition[record.id].map {
                NamedFeatureVectorView(values: $0, names: featureNames)
            }
            return InteractionEventView(record: record, featureVector: vec)
        }

        let adjustmentViews = lastSearchEntries.map { AdjustmentEntryView(from: $0) }

        return FrankParkingResponse(
            pendingParked:           pendingParked,
            recentInteractions:      interactionEvents,
            lastSentiment:           lastSentiment.map { SentimentView(from: $0) },
            lastSearchAdjustments:   adjustmentViews,
            interactionHistoryCount: collector?.interactionHistoryCount ?? 0,
            dataSetSize:             dataSet?.size ?? 0,
            minimumTrainingSamples:  RetrievalDataCollector.minimumTrainingSamples,
            featureVectorReadyAt:    20,
            isTrained:               (model?.totalTrees ?? 0) > 0,
            totalTrees:              model?.totalTrees ?? 0,
            indicatorPeriods:        IndicatorPeriodsView(from: collector?.periods ?? .default),
            harmonyMemory:           harmonyMem.map { HarmonyMemoryView(from: $0) },
            trajectory:              lastTrajectory
        )
    }

    // MARK: POST /v1/frank/reset

    router.post("/v1/frank/reset") { request, context async throws -> FrankResetResponse in
        let body    = try await request.decode(as: FrankGBTRequest.self, context: context)
        let sewnReq = try body.sewn.from(context)

        let hadData = sewn.sinatra.removeOwner(id: sewnReq.ownerId)

        return FrankResetResponse(reset: hadData, ownerId: sewnReq.ownerId)
    }

    // MARK: POST /v1/frank/export

    router.post("/v1/frank/export") { request, context async throws -> SinatraExport in
        let body    = try await request.decode(as: FrankGBTRequest.self, context: context)
        let sewnReq = try body.sewn.from(context)
        let owner   = SewnRegistry.Owner(id: sewnReq.ownerId)

        let registry = sewn.sinatra.registry

        return SinatraExport(
            ownerId:           sewnReq.ownerId,
            parked:            registry?.parked[owner] ?? [],
            collector:         registry?.collectors[owner],
            dataSet:           registry?.dataSets[owner],
            model:             registry?.models[owner],
            harmonyMemory:     registry?.harmonyMemories[owner],
            lastSentiment:     registry?.lastSentiments[owner],
            lastSearchEntries: registry?.lastSearchEntries[owner] ?? [],
            lastTrajectory:    registry?.lastTrajectories[owner]
        )
    }

    // MARK: POST /v1/frank/import

    router.post("/v1/frank/import") { request, context async throws -> FrankImportResponse in
        let body    = try await request.decode(as: FrankImportRequest.self, context: context)
        let sewnReq = try body.sewn.from(context)

        sewn.sinatra.importOwner(id: sewnReq.ownerId, from: body.export)

        return FrankImportResponse(
            imported: true,
            ownerId:  sewnReq.ownerId,
            summary:  body.export.summary
        )
    }
}
