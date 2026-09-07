//
//  Sinatra.Tone.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/20/26.
//

import Foundation

/// Generation parameter set derived from Sinatra's retrieval adjustments.
/// A `SinatraTone` communicates how confident the retrieval layer is, letting
/// the generation layer respond with proportionally more focused or more
/// exploratory output.
struct SinatraTone: Codable {
    var temperature: Float
    var topP: Float
    var repetitionPenalty: Float
    var repetitionContextSize: Int

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP                 = "top_p"
        case repetitionPenalty    = "repetition_penalty"
        case repetitionContextSize = "repetition_context_size"
    }

    /// Baseline values applied when no Sinatra adjustment data is available.
    static let base = SinatraTone(
        temperature: 0.4,
        topP: 0.9,
        repetitionPenalty: 1.1,
        repetitionContextSize: 20
    )

    /// Derives a `SinatraTone` from an array of `SinatraAdjustment` records
    /// produced during partition retrieval.
    ///
    /// **Algorithm — contraction-weighted confidence:**
    ///
    /// Each `SinatraAdjustment` records the PQ distances *before* and *after*
    /// Sinatra's SVM inference step.  When the inferred distances are lower on
    /// average than the original PQ distances, Sinatra has promoted high-quality
    /// partitions closer to the top — the retrieval context is more reliable.
    ///
    /// 1. Parse every distance string across all adjustments into Floats.
    /// 2. Compute the contraction ratio `avgOriginal / avgInferred`.
    ///    - `> 1` → distances tightened  (high retrieval confidence)
    ///    - `< 1` → distances expanded   (low retrieval confidence)
    /// 3. Map the ratio from the empirical range `[0.5, 2.0]` to `[0.0, 1.0]`.
    /// 4. Scale each generation parameter linearly between its base value and
    ///    its high-confidence target:
    ///    - `temperature`          `[0.40 → 0.25]` — more focused at high confidence
    ///    - `topP`                 `[0.90 → 0.75]` — narrower nucleus at high confidence
    ///    - `repetitionPenalty`    `[1.10 → 1.20]` — stronger penalty with rich context
    ///    - `repetitionContextSize`  `[20 → 30]`   — wider look-back with rich context
    ///
    /// - Parameter adjustments: Adjustments collected during the current search.
    /// - Returns: A tuned `SinatraTone`, or `.base` when no signal is present.
    static func from(_ adjustments: [SinatraAdjustment]) -> SinatraTone {
        guard !adjustments.isEmpty else { return .base }

        let originalDistances = adjustments.flatMap { $0.original.compactMap(Float.init) }
        let inferredDistances = adjustments.flatMap { $0.inferred.compactMap(Float.init) }

        guard !originalDistances.isEmpty, !inferredDistances.isEmpty else { return .base }

        let avgOriginal = originalDistances.reduce(0, +) / Float(originalDistances.count)
        let avgInferred = inferredDistances.reduce(0, +) / Float(inferredDistances.count)

        // Contraction ratio: how much Sinatra tightened the distances.
        let contraction = avgOriginal / max(avgInferred, 1e-4)

        // Normalize [0.5, 2.0] → [0.0, 1.0]; clamp outside that empirical band.
        let confidence = min(max((contraction - 0.5) / 1.5, 0.0), 1.0)

        return SinatraTone(
            temperature:           0.4  - 0.15 * confidence,       // [0.25, 0.40]
            topP:                  0.9  - 0.15 * confidence,        // [0.75, 0.90]
            repetitionPenalty:     1.1  + 0.10 * confidence,        // [1.10, 1.20]
            repetitionContextSize: 20   + Int(10.0 * confidence)    // [20,   30  ]
        )
    }
}
