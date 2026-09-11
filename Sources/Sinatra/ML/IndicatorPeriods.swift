//
//  IndicatorPeriods.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/18/26.
//

import Foundation

// === INDICATOR PERIOD CONFIGURATION ===
//
// Encodes all lookback-window period parameters for `TechnicalIndicators`.
// Used by `HarmonyMemory` as the IMBHS decision variable vector (11 dimensions).
// Hard-coded period constants in `RetrievalDataCollector` are replaced by
// an `IndicatorPeriods` instance whose values are tuned at runtime.

struct IndicatorPeriods: Codable, Equatable {
    // Level indicators
    var emaPeriod: Int         // emaWA(period:)                    — default 10
    var smaPeriod: Int         // smaWA(period:)                    — default 20

    // EMA-momentum indicators
    var macdFast: Int          // macD(fastPeriod:)                 — default 5
    var macdSlow: Int          // macD(slowPeriod:)                 — default 15
    var macdSignalPeriod: Int  // macDSignal(signalPeriod:)         — default 9

    // Oscillator indicators
    var stochKPeriod: Int      // stochasticK(period:)              — default 14
    var stochDSignal: Int      // stochasticD(signalPeriod:)        — default 3

    // Raw differential indicators
    var momentumPeriod: Int    // momentum(period:)                 — default 10
    var velocityPeriod: Int    // velocity(period:)                 — default 10

    // Volume indicators
    var avgVolPeriod: Int      // avgVolChange(period:)             — default 10
    var vwaPeriod: Int         // volumeWeightedAverage(period:)    — default 15

    // MARK: - Default

    static let `default` = IndicatorPeriods(
        emaPeriod: 10, smaPeriod: 20,
        macdFast: 5, macdSlow: 15, macdSignalPeriod: 9,
        stochKPeriod: 14, stochDSignal: 3,
        momentumPeriod: 10, velocityPeriod: 10,
        avgVolPeriod: 10, vwaPeriod: 15
    )

    // MARK: - Bounds
    // Per-parameter (min, max) bounds.
    // Derived from the 20-interaction history minimum and joint feasibility constraints.

    static let bounds: [(min: Int, max: Int)] = [
        (5, 20),   // emaPeriod
        (10, 20),  // smaPeriod
        (3, 10),   // macdFast
        (10, 18),  // macdSlow      (must > macdFast; upper bound leaves room for fast)
        (3, 15),   // macdSignalPeriod
        (5, 16),   // stochKPeriod  (joint: stochKPeriod + stochDSignal - 1 ≤ 20)
        (2, 5),    // stochDSignal  (joint: same constraint)
        (3, 18),   // momentumPeriod (period + 2 ≤ 20)
        (3, 18),   // velocityPeriod (period + 2 ≤ 20)
        (5, 15),   // avgVolPeriod  (period + 1 ≤ 20)
        (5, 20),   // vwaPeriod
    ]

    // MARK: - Array representation

    /// Flat ordered array of the 11 period values, matching the `bounds` order.
    var asArray: [Int] {
        [emaPeriod, smaPeriod, macdFast, macdSlow, macdSignalPeriod,
         stochKPeriod, stochDSignal, momentumPeriod, velocityPeriod,
         avgVolPeriod, vwaPeriod]
    }

    /// Construct from a flat 11-element array (must match `bounds` order).
    init(fromArray array: [Int]) {
        precondition(array.count == Self.bounds.count, "IndicatorPeriods array must have \(Self.bounds.count) elements")
        emaPeriod        = array[0]
        smaPeriod        = array[1]
        macdFast         = array[2]
        macdSlow         = array[3]
        macdSignalPeriod = array[4]
        stochKPeriod     = array[5]
        stochDSignal     = array[6]
        momentumPeriod   = array[7]
        velocityPeriod   = array[8]
        avgVolPeriod     = array[9]
        vwaPeriod        = array[10]
    }

    init(
        emaPeriod: Int, smaPeriod: Int,
        macdFast: Int, macdSlow: Int, macdSignalPeriod: Int,
        stochKPeriod: Int, stochDSignal: Int,
        momentumPeriod: Int, velocityPeriod: Int,
        avgVolPeriod: Int, vwaPeriod: Int
    ) {
        self.emaPeriod = emaPeriod
        self.smaPeriod = smaPeriod
        self.macdFast = macdFast
        self.macdSlow = macdSlow
        self.macdSignalPeriod = macdSignalPeriod
        self.stochKPeriod = stochKPeriod
        self.stochDSignal = stochDSignal
        self.momentumPeriod = momentumPeriod
        self.velocityPeriod = velocityPeriod
        self.avgVolPeriod = avgVolPeriod
        self.vwaPeriod = vwaPeriod
    }

    // MARK: - Logging

    /// Compact one-line description of all 11 period values, grouped semantically.
    /// Used in IMBHS log summaries without flooding with 11 separate fields.
    /// Example: "ema10/sma20 macd5·15·9 stoch14·3 mom10/vel10 vol10/vwa15"
    var logDescription: String {
        "ema\(emaPeriod)/sma\(smaPeriod) macd\(macdFast)·\(macdSlow)·\(macdSignalPeriod) stoch\(stochKPeriod)·\(stochDSignal) mom\(momentumPeriod)/vel\(velocityPeriod) vol\(avgVolPeriod)/vwa\(vwaPeriod)"
    }

    // MARK: - Feasibility

    /// Returns a copy with all individual bounds and joint constraints enforced.
    ///
    /// Joint constraints:
    /// - `macdFast < macdSlow`
    /// - `stochKPeriod + stochDSignal - 1 ≤ 20`
    func feasible() -> IndicatorPeriods {
        var p = self

        // Clamp individual bounds
        p.emaPeriod        = p.emaPeriod.clamped(5, 20)
        p.smaPeriod        = p.smaPeriod.clamped(10, 20)
        p.macdFast         = p.macdFast.clamped(3, 10)
        p.macdSlow         = p.macdSlow.clamped(10, 18)
        p.macdSignalPeriod = p.macdSignalPeriod.clamped(3, 15)
        p.stochKPeriod     = p.stochKPeriod.clamped(5, 16)
        p.stochDSignal     = p.stochDSignal.clamped(2, 5)
        p.momentumPeriod   = p.momentumPeriod.clamped(3, 18)
        p.velocityPeriod   = p.velocityPeriod.clamped(3, 18)
        p.avgVolPeriod     = p.avgVolPeriod.clamped(5, 15)
        p.vwaPeriod        = p.vwaPeriod.clamped(5, 20)

        // Joint: macdFast must be strictly less than macdSlow
        if p.macdFast >= p.macdSlow {
            p.macdFast = max(3, p.macdSlow - 1)
        }

        // Joint: stochKPeriod + stochDSignal - 1 ≤ 20
        if p.stochKPeriod + p.stochDSignal - 1 > 20 {
            p.stochKPeriod = max(5, 20 - p.stochDSignal + 1)
        }

        return p
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int {
        Swift.min(Swift.max(self, lo), hi)
    }
}
