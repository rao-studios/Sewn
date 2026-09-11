//
//  Sinatra.TrainingData.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 1/25/26.
//

import Foundation

struct SinatraTrainingData: Codable {
    struct Parked: Codable {
        // Partition ID (content-addressed SHA-256 hash of the embedding).
        var id: String
        /// The document this partition belongs to.
        /// Used to key performance stats in `SewnRegistry.documentStats` correctly.
        /// Backward compat: old persisted entries default to `""`.
        var documentId: String
        var partitionCompressedEmbedding: [UInt16]?
        var distance: Float
        /// When the partition was parked (end of the search that produced it).
        /// Used at the next prepare() call to compute response latency as a
        /// proxy for how long the user took to reply after the assistant responded.
        var parkedAt: Date

        // Legacy keys kept in CodingKeys so the custom decoder can silently skip
        // old persisted `queryEmbedding` / `partitionEmbedding` values without
        // throwing. The fields themselves are gone — ~8 KB per entry eliminated.
        enum CodingKeys: String, CodingKey {
            case id, documentId
            case queryEmbedding, partitionEmbedding  // legacy — decode-and-discard only
            case partitionCompressedEmbedding, distance, parkedAt
        }

        init(id: String,
             documentId: String = "",
             partitionCompressedEmbedding: [UInt16]? = nil,
             distance: Float,
             parkedAt: Date = Date()) {
            self.id = id
            self.documentId = documentId
            self.partitionCompressedEmbedding = partitionCompressedEmbedding
            self.distance = distance
            self.parkedAt = parkedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id                           = try c.decode(String.self,    forKey: .id)
            // Backward compat: old entries lack documentId; fall back to "" so
            // stats lookups degrade gracefully (no crash, slightly wrong key).
            documentId                   = try c.decodeIfPresent(String.self, forKey: .documentId) ?? ""
            // Silently discard legacy embedding arrays — they were never read in
            // training or inference, just occupied ~8 KB per parked entry.
            _ = try c.decodeIfPresent([Float].self, forKey: .queryEmbedding)
            _ = try c.decodeIfPresent([Float].self, forKey: .partitionEmbedding)
            partitionCompressedEmbedding = try c.decodeIfPresent([UInt16].self, forKey: .partitionCompressedEmbedding)
            distance                     = try c.decode(Float.self,     forKey: .distance)
            // Backward compat: old encoded data lacks parkedAt; default to now so
            // latency reads as ~0 (one-off pattern), which is safe.
            parkedAt                     = try c.decodeIfPresent(Date.self, forKey: .parkedAt) ?? Date()
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id,                           forKey: .id)
            try c.encode(documentId,                   forKey: .documentId)
            try c.encodeIfPresent(partitionCompressedEmbedding, forKey: .partitionCompressedEmbedding)
            try c.encode(distance,                     forKey: .distance)
            try c.encode(parkedAt,                     forKey: .parkedAt)
            // queryEmbedding and partitionEmbedding intentionally omitted.
        }
    }
    
    struct ParkedIndex: Codable {
        var documentId: String
        /// Exact tag distance (1.0 - dot) at filter time. Nil when tagDistance() returned nil (untagged doc).
        var tagDistance: Float?
        /// Whether this document passed the tag pre-filter for this search.
        var wasIncluded: Bool
        var parkedAt: Date

        init(documentId: String, tagDistance: Float?, wasIncluded: Bool, parkedAt: Date = Date()) {
            self.documentId = documentId
            self.tagDistance = tagDistance
            self.wasIncluded = wasIncluded
            self.parkedAt = parkedAt
        }
    }

    var date: Date = .now

    var parked: Parked
    var sentiment: Float
}
