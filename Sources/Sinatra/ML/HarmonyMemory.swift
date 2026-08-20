//
//  HarmonyMemory.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/18/26.
//

import Foundation

// === IMBHS HARMONY MEMORY ===
//
// Implements the Improved Music-Based Harmony Search algorithm to tune
// the period parameters in `IndicatorPeriods` at runtime.
//
// Terminology mapping (IMBHS → Sinatra):
//   Harmony vector  → IndicatorPeriods (11 integer dimensions)
//   Harmony memory  → population of H=10 candidate period configs
//   Generation gn   → one SVM training cycle in prepare()
//   Fitness f(h)    → leave-recent-out MAE from current SVR model
//   PAR(gn)         → linear 0.1→0.5 over NI=200 cycles
//   BW(gn)          → exponential 3→1 over NI=200 cycles

struct HarmonyMemory: Codable {

    // MARK: - IMBHS Constants

    static let memorySize: Int       = 10     // H: number of harmonies
    static let hmcr: Double          = 0.9    // harmony memory considering rate
    static let parMin: Double        = 0.1    // minimum pitch adjustment rate
    static let parMax: Double        = 0.5    // maximum pitch adjustment rate
    static let bwMax: Int            = 3      // max period step per dimension
    static let bwMin: Int            = 1      // min period step (floor)
    static let ni: Int               = 200    // optimization horizon (cycles)
    static let cadence: Int          = 5      // run every M training cycles
    static let warmup: Int           = 20     // minimum cycles before activation
    static let fitnessThreshold: Double = 0.01  // 1% MAE improvement to apply

    // MARK: - State

    private(set) var harmonies: [IndicatorPeriods]
    private(set) var fitness: [Double]          // MAE; lower = better; .infinity = unevaluated
    private(set) var generation: Int
    private(set) var activePeriods: IndicatorPeriods

    // MARK: - Init

    init() {
        var h = [IndicatorPeriods]()
        h.append(.default)
        for _ in 1..<HarmonyMemory.memorySize {
            h.append(HarmonyMemory.randomHarmony())
        }
        harmonies     = h
        fitness       = Array(repeating: .infinity, count: HarmonyMemory.memorySize)
        generation    = 0
        activePeriods = .default
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case harmonies, fitness, generation, activePeriods
    }

    init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        harmonies     = try c.decode([IndicatorPeriods].self, forKey: .harmonies)
        fitness       = try c.decode([Double].self, forKey: .fitness)
        generation    = try c.decode(Int.self, forKey: .generation)
        activePeriods = try c.decodeIfPresent(IndicatorPeriods.self, forKey: .activePeriods) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(harmonies, forKey: .harmonies)
        // JSON encoders reject Double.infinity; map unevaluated sentinels to
        // greatestFiniteMagnitude, which compares identically for the algorithm.
        let encodableFitness = fitness.map { $0.isFinite ? $0 : Double.greatestFiniteMagnitude }
        try c.encode(encodableFitness, forKey: .fitness)
        try c.encode(generation,    forKey: .generation)
        try c.encode(activePeriods, forKey: .activePeriods)
    }

    // MARK: - Schedule

    /// PAR(gn): increases linearly from parMin → parMax over NI cycles.
    var currentPAR: Double {
        let gn = Swift.min(generation, Self.ni)
        return Self.parMin + (Self.parMax - Self.parMin) / Double(Self.ni) * Double(gn)
    }

    /// BW(gn): decreases exponentially from bwMax → bwMin over NI cycles.
    var currentBW: Int {
        let gn = Swift.min(generation, Self.ni)
        let c  = log(Double(Self.bwMax) / Double(Self.bwMin)) / Double(Self.ni)
        let bw = Double(Self.bwMax) * exp(-c * Double(gn))
        return Swift.max(Self.bwMin, Int(bw.rounded()))
    }

    // MARK: - Improvisation

    /// Generate a new candidate harmony using IMBHS improvisation:
    ///   - With prob HMCR: pick a value from HM, then with prob PAR adjust by ±BW.
    ///   - With prob (1-HMCR): pick uniformly at random within bounds.
    func improvise() -> IndicatorPeriods {
        let par    = currentPAR
        let bw     = currentBW
        let bounds = IndicatorPeriods.bounds
        var raw    = [Int](repeating: 0, count: bounds.count)

        for d in 0..<bounds.count {
            let lo = bounds[d].min
            let hi = bounds[d].max

            if Double.random(in: 0..<1) < Self.hmcr {
                // Pick from a random harmony in memory
                let source = harmonies[Int.random(in: 0..<harmonies.count)].asArray
                var val    = source[d]
                // Pitch adjustment
                if Double.random(in: 0..<1) < par {
                    let sign = Bool.random() ? 1 : -1
                    let step = Int.random(in: 1...bw) * sign
                    val      = Swift.min(Swift.max(val + step, lo), hi)
                }
                raw[d] = val
            } else {
                raw[d] = Int.random(in: lo...hi)
            }
        }

        return IndicatorPeriods(fromArray: raw).feasible()
    }

    // MARK: - Update

    /// Attempts to replace the worst harmony in memory with `candidate`.
    /// If the overall best harmony in memory changes and the fitness
    /// improvement exceeds `fitnessThreshold`, updates `activePeriods`.
    ///
    /// Returns `true` if `activePeriods` changed (caller should rebuild).
    @discardableResult
    mutating func update(candidate: IndicatorPeriods, candidateFitness: Double) -> Bool {
        // Replace worst only if candidate is strictly better
        guard let worstIdx = fitness.indices.max(by: { fitness[$0] < fitness[$1] }) else { return false }
        guard candidateFitness < fitness[worstIdx] else { return false }

        harmonies[worstIdx] = candidate
        fitness[worstIdx]   = candidateFitness

        // Find new best
        guard let bestIdx = fitness.indices.min(by: { fitness[$0] < fitness[$1] }) else { return false }
        let newBest     = harmonies[bestIdx]
        let bestFitness = fitness[bestIdx]
        guard newBest != activePeriods else { return false }

        // Look up current active periods' fitness in HM (may have been evicted)
        let activeFitness = zip(harmonies, fitness)
            .first(where: { $0.0 == activePeriods })?.1

        if let af = activeFitness, af.isFinite {
            // Require meaningful improvement before thrashing the dataset/retrain
            let improvement = (af - bestFitness) / af
            guard improvement >= Self.fitnessThreshold else { return false }
        }
        // If active periods are unevaluated (.infinity) or evicted from HM,
        // accept any improvement freely.

        activePeriods = newBest
        return true
    }

    // MARK: - Generation bookkeeping

    /// Increment the generation counter. Call after each successful SVM training cycle.
    mutating func incrementGeneration() {
        generation += 1
    }

    /// Whether IMBHS improvisation should run this generation.
    var shouldRun: Bool {
        generation >= Self.warmup && generation % Self.cadence == 0
    }

    // MARK: - Private helpers

    private static func randomHarmony() -> IndicatorPeriods {
        let bounds = IndicatorPeriods.bounds
        let raw    = bounds.map { Int.random(in: $0.min...$0.max) }
        return IndicatorPeriods(fromArray: raw).feasible()
    }
}
