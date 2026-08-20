//
//  SinatraExport.swift
//  seer-server
//

import Foundation


/// A portable snapshot of a single owner's complete Sinatra state.
///
/// Used by `POST /v1/frank/export` and `POST /v1/frank/import` to transfer
/// a trained model + interaction history between accounts or to a local file.
///
/// The `ownerId` field is informational metadata from the exporting account.
/// On import, the authenticated requester's owner ID is always applied — this
/// is what enables account-to-account transfer.
struct SinatraExport: Codable {

    /// Incremented when the schema changes in a breaking way.
    static let currentVersion = 1

    // MARK: Metadata

    let version: Int
    let exportedAt: Date
    /// The owner ID from the account that produced this export.
    /// Ignored during import — the auth'd requester's ID is used instead.
    let ownerId: String

    // MARK: Core ML State

    /// Partitions from recent searches that haven't received sentiment feedback yet.
    let parked: [SinatraTrainingData.Parked]
    /// Interaction history + technical indicator state.
    let collector: RetrievalDataCollector?
    /// Training data — 14-D feature vectors paired with sentiment weights.
    let dataSet: DataSet?
    /// Trained gradient-boosted tree ensemble.
    let model: GBTModel?
    /// IMBHS harmony search state for tuning indicator periods.
    let harmonyMemory: HarmonyMemory?

    // MARK: Snapshot State

    let lastSentiment: Sinatra.Sentiment?
    let lastSearchEntries: [SinatraAdjustment.Entry]
    let lastTrajectory: SinatraTrajectorySnapshot?

    // MARK: Init

    init(
        ownerId: String,
        parked: [SinatraTrainingData.Parked],
        collector: RetrievalDataCollector?,
        dataSet: DataSet?,
        model: GBTModel?,
        harmonyMemory: HarmonyMemory?,
        lastSentiment: Sinatra.Sentiment?,
        lastSearchEntries: [SinatraAdjustment.Entry],
        lastTrajectory: SinatraTrajectorySnapshot?
    ) {
        self.version           = SinatraExport.currentVersion
        self.exportedAt        = Date()
        self.ownerId           = ownerId
        self.parked            = parked
        self.collector         = collector
        self.dataSet           = dataSet
        self.model             = model
        self.harmonyMemory     = harmonyMemory
        self.lastSentiment     = lastSentiment
        self.lastSearchEntries = lastSearchEntries
        self.lastTrajectory    = lastTrajectory
    }

    // MARK: Coding Keys

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt        = "exported_at"
        case ownerId           = "owner_id"
        case parked
        case collector
        case dataSet           = "data_set"
        case model
        case harmonyMemory     = "harmony_memory"
        case lastSentiment     = "last_sentiment"
        case lastSearchEntries = "last_search_entries"
        case lastTrajectory    = "last_trajectory"
    }

    // MARK: Summary

    var summary: SinatraExportSummary {
        SinatraExportSummary(
            version:                version,
            exportedAt:             exportedAt,
            ownerId:                ownerId,
            parkedCount:            parked.count,
            interactionHistoryCount: collector?.interactionHistoryCount ?? 0,
            dataSetSize:            dataSet?.size ?? 0,
            isTrained:              (model?.totalTrees ?? 0) > 0,
            totalTrees:             model?.totalTrees ?? 0,
            hasHarmonyMemory:       harmonyMemory != nil
        )
    }
}

/// Lightweight metadata describing a `SinatraExport` without its bulk data.
/// Returned by the import route so the caller can confirm what was applied.
struct SinatraExportSummary: Codable {
    let version: Int
    let exportedAt: Date
    let ownerId: String
    let parkedCount: Int
    let interactionHistoryCount: Int
    let dataSetSize: Int
    let isTrained: Bool
    let totalTrees: Int
    let hasHarmonyMemory: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt             = "exported_at"
        case ownerId                = "owner_id"
        case parkedCount            = "parked_count"
        case interactionHistoryCount = "interaction_history_count"
        case dataSetSize            = "data_set_size"
        case isTrained              = "is_trained"
        case totalTrees             = "total_trees"
        case hasHarmonyMemory       = "has_harmony_memory"
    }
}
