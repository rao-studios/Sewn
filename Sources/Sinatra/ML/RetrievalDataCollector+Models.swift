//
//  RetrievalDataCollector+Models.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/8/26.
//

import Foundation

// === INTERACTION RECORD ===
struct InteractionRecord: Codable {
    let timestamp: Date
    let sentimentWeight: Double  // From sentiment.calculateWeight(), possibly scaled by engagementComposite
    let responseLength: Int
    /// Partition ID (content-addressed hash) — used as the GBT training label.
    let id: String
    /// Document ID this partition belongs to.
    /// Used to look up `DocumentStats` in `buildDataSet` and `evaluateFitness`.
    /// Backward compat: old serialised records default to `""` (no document lookup).
    let documentId: String
    /// Normalised pace score [0, 1]: responseLatency / (assistantWordCount × 0.3).
    /// Represents how much of the response the user likely read before replying.
    let paceScore: Double
    /// Weighted attentiveness score [0, 1]: referenced(0.4) + answered(0.4) + building(0.2).
    let attentivenessScore: Double

    enum CodingKeys: String, CodingKey {
        case timestamp, sentimentWeight, responseLength, id, documentId, paceScore, attentivenessScore
    }

    init(timestamp: Date,
         sentimentWeight: Double,
         responseLength: Int,
         id: String,
         documentId: String = "",
         paceScore: Double = 0.5,
         attentivenessScore: Double = 0.0) {
        self.timestamp          = timestamp
        self.sentimentWeight    = sentimentWeight
        self.responseLength     = responseLength
        self.id                 = id
        self.documentId         = documentId
        self.paceScore          = paceScore
        self.attentivenessScore = attentivenessScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp          = try c.decode(Date.self,   forKey: .timestamp)
        sentimentWeight    = try c.decode(Double.self,  forKey: .sentimentWeight)
        responseLength     = try c.decode(Int.self,    forKey: .responseLength)
        id                 = try c.decode(String.self,  forKey: .id)
        // Backward compat: old records lack documentId; fall back to "" so
        // DocumentStats lookups simply miss and use the neutral 0.5 prior.
        documentId         = try c.decodeIfPresent(String.self, forKey: .documentId) ?? ""
        // Default 0.5 pace (mid-range) and 0.0 attentiveness for old records so they
        // contribute neutrally to the GBT without creating a false engagement spike.
        paceScore          = try c.decodeIfPresent(Double.self, forKey: .paceScore) ?? 0.5
        attentivenessScore = try c.decodeIfPresent(Double.self, forKey: .attentivenessScore) ?? 0.0
    }
}

