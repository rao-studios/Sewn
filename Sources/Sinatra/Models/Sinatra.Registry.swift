//
//  Sinatra.Registry.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 1/25/26.
//

import Foundation

struct SinatraRegistry: Codable {
    /*
     This is built for an ephemeral chat session. Or a single chat session.
     If this can handle multiple chats then we would need to also key via
     a chat session id.
     */
    var parked: [SeerRegistry.Owner: [SinatraTrainingData.Parked]] = [:]
    var parkedIndices: [SeerRegistry.Owner: [SinatraTrainingData.ParkedIndex]] = [:]
    var collectors: [SeerRegistry.Owner : RetrievalDataCollector] = [:]
    var dataSets: [SeerRegistry.Owner : DataSet] = [:]
    var models: [SeerRegistry.Owner : GBTModel] = [:]
    var harmonyMemories: [SeerRegistry.Owner : HarmonyMemory] = [:]
    /// Most recent sentiment result per owner — written after each sentiment cycle,
    /// exposed via the /v1/frank/parking debug route.
    var lastSentiments: [SeerRegistry.Owner : Sinatra.Sentiment] = [:]
    /// Per-partition GBT adjustment entries from the most recent search per owner.
    /// Written after each search; not persisted across restarts (decoded with fallback to []).
    var lastSearchEntries: [SeerRegistry.Owner : [SinatraAdjustment.Entry]] = [:]
    /// Trajectory snapshot from the most recent prepare() cycle per owner.
    /// Exposed via /v1/frank/parking for the Trajectory debug tab.
    var lastTrajectories: [SeerRegistry.Owner : SinatraTrajectorySnapshot] = [:]

    enum CodingKeys: String, CodingKey {
        case parked, parkedIndices, collectors, dataSets, models, harmonyMemories, lastSentiments, lastSearchEntries, lastTrajectories
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container   = try decoder.container(keyedBy: CodingKeys.self)
        parked          = try container.decodeIfPresent([SeerRegistry.Owner: [SinatraTrainingData.Parked]].self,      forKey: .parked)         ?? [:]
        parkedIndices   = try container.decodeIfPresent([SeerRegistry.Owner: [SinatraTrainingData.ParkedIndex]].self, forKey: .parkedIndices)  ?? [:]
        collectors      = try container.decodeIfPresent([SeerRegistry.Owner: RetrievalDataCollector].self,      forKey: .collectors)      ?? [:]
        dataSets        = try container.decodeIfPresent([SeerRegistry.Owner: DataSet].self,                     forKey: .dataSets)         ?? [:]
        // Graceful fallback: existing SVMModel JSON under "models" will fail to decode as GBTModel.
        // On failure, models start empty — each owner's GBTModel is rebuilt from their DataSet
        // within one prepare() call. DataSet persists correctly; no interaction history is lost.
        models          = (try? container.decode([SeerRegistry.Owner: GBTModel].self, forKey: .models))                                    ?? [:]
        harmonyMemories   = try container.decodeIfPresent([SeerRegistry.Owner: HarmonyMemory].self,                       forKey: .harmonyMemories)   ?? [:]
        lastSentiments    = try container.decodeIfPresent([SeerRegistry.Owner: Sinatra.Sentiment].self,                  forKey: .lastSentiments)    ?? [:]
        lastSearchEntries = try container.decodeIfPresent([SeerRegistry.Owner: [SinatraAdjustment.Entry]].self,          forKey: .lastSearchEntries) ?? [:]
        lastTrajectories  = try container.decodeIfPresent([SeerRegistry.Owner: SinatraTrajectorySnapshot].self,          forKey: .lastTrajectories)  ?? [:]
    }
}
