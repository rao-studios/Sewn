//
//  Sewn+Marielle.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//

import Foundation

// MARK: - Constants

extension Sewn {
    static let mariellOpenCandidateK:      Int   = 12
    static let mariellInterjectCandidateK: Int   = 8
    static let mariellBridgeCandidateK:    Int   = 10

    static let mariellProactiveTriggerThreshold:  Float = 0.55
    static let mariellInterjectTriggerThreshold:  Float = 0.50
    static let mariellInterjectMinSessionDepth:   Int   = 3

    static let mariellBridgeSimilarityFloor:      Float = 0.40
    static let mariellRecencyHalfLifeDays:        Float = 14.0
    static let mariellMemoryHalfLifeDays:         Float = 7.0
    static let mariellProactiveCooldownHours:     Float = 4.0
}

// MARK: - Cosine similarity

extension Sewn {
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot:   Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    func centroid(of embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for v in embeddings {
            guard v.count == dim else { continue }
            for i in 0..<dim { sum[i] += v[i] }
        }
        let n = Float(embeddings.count)
        return sum.map { $0 / n }
    }
}

// MARK: - Interjection score (pure math — no HNSW dependency)

extension Sewn {
    func mariellInterjectScore(
        sessionDepth:         Int,
        conversationDrift:    Float,
        unretrievedRelevance: Float,
        topicSaturation:      Float
    ) -> Float {
        guard sessionDepth >= Self.mariellInterjectMinSessionDepth else { return 0 }
        let depth = min(Float(sessionDepth) / 10.0, 1.0)
        return (unretrievedRelevance * 0.45)
             + (topicSaturation      * 0.25)
             + (conversationDrift    * 0.15)
             + (depth                * 0.15)
    }
}
