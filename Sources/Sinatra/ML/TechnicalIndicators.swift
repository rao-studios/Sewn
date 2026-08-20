//
//  TechnicalIndicators.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/8/26.
//

import Foundation

// === TECHNICAL INDICATORS ===

struct TechnicalIndicators {
    private let sentimentHistory: [Double]
    private let timestampHistory: [Date]
    private let responseLengthHistory: [Int]
    
    init(history: [InteractionRecord]) {
        self.sentimentHistory = history.map { $0.sentimentWeight }
        self.timestampHistory = history.map { $0.timestamp }
        self.responseLengthHistory = history.map { $0.responseLength }
    }
    
    // === EMA Weighted Average ===
    func emaWA(period: Int = 10, alpha: Double = 0.3) -> Double {
        guard sentimentHistory.count >= period else { return 0.5 }
        
        let window = sentimentHistory.suffix(period)
        var ema = window.first!
        
        for value in window.dropFirst() {
            ema = alpha * value + (1 - alpha) * ema
        }
        
        return ema
    }
    
    // === SMA Weighted Average ===
    func smaWA(period: Int = 20) -> Double {
        guard sentimentHistory.count >= period else { return 0.5 }
        
        let window = sentimentHistory.suffix(period)
        return window.reduce(0, +) / Double(period)
    }
    
    // === MACD ===
    func macD(fastPeriod: Int = 5, slowPeriod: Int = 15) -> Double {
        let fastEMA = emaWA(period: fastPeriod, alpha: 0.4)
        let slowEMA = emaWA(period: slowPeriod, alpha: 0.2)
        return fastEMA - slowEMA
    }
    
    // === MACD Signal Line (EMA of MACD values) ===
    func macDSignal(macdHistory: [Double], signalPeriod: Int = 9) -> Double {
        guard macdHistory.count >= signalPeriod else { return 0.0 }
        
        let window = macdHistory.suffix(signalPeriod)
        var ema = window.first!
        
        for value in window.dropFirst() {
            ema = 0.3 * value + 0.7 * ema
        }
        
        return ema
    }
    
    // === MACD Previous Signal ===
    func macDPreviousSignal(macdHistory: [Double]) -> Double {
        guard macdHistory.count >= 10 else { return 0.0 }
        
        // Get MACD history up to previous turn
        let previousMACDHistory = Array(macdHistory.dropLast())
        return macDSignal(macdHistory: previousMACDHistory, signalPeriod: 9)
    }
    
    // === Average Volume Change ===
    /// - Parameter lifetimeAvgInterval: Precomputed lifetime average interval
    ///   from `RetrievalDataCollector`. When provided, used as the historical
    ///   baseline instead of computing from the (potentially trimmed) history.
    func avgVolChange(period: Int = 10, lifetimeAvgInterval: Double? = nil) -> Double {
        guard timestampHistory.count >= period + 1 else { return 0.0 }

        // Calculate recent interaction intervals (proxy for volume)
        let recentTimestamps = timestampHistory.suffix(period + 1)
        let recentIntervals = zip(recentTimestamps.dropLast(), recentTimestamps.dropFirst())
            .map { $1.timeIntervalSince($0) }

        guard !recentIntervals.isEmpty else { return 0.0 }

        let recentAvgInterval = recentIntervals.reduce(0, +) / Double(recentIntervals.count)

        // Use lifetime average if provided, otherwise fall back to in-window history
        let historicalAvgInterval: Double
        if let lifetime = lifetimeAvgInterval, lifetime > 0 {
            historicalAvgInterval = lifetime
        } else {
            let allIntervals = zip(timestampHistory.dropLast(), timestampHistory.dropFirst())
                .map { $1.timeIntervalSince($0) }
            guard !allIntervals.isEmpty else { return 0.0 }
            historicalAvgInterval = allIntervals.reduce(0, +) / Double(allIntervals.count)
        }

        guard historicalAvgInterval > 0 else { return 0.0 }

        // Positive = faster interaction (volume increase)
        // Negative = slower interaction (volume decrease)
        return (historicalAvgInterval - recentAvgInterval) / historicalAvgInterval
    }
    
    // === Stochastic %K ===
    /// Where the current sentiment sits within its recent high-low range.
    /// Returns [0, 1]: 1 = at recent peak, 0 = at recent trough, 0.5 = neutral/no range.
    func stochasticK(period: Int = 14) -> Double {
        guard sentimentHistory.count >= period else { return 0.5 }

        let window = Array(sentimentHistory.suffix(period))
        guard let minVal = window.min(), let maxVal = window.max() else { return 0.5 }
        guard maxVal > minVal else { return 0.5 }

        let current = window.last!
        return (current - minVal) / (maxVal - minVal)
    }

    // === Stochastic %D ===
    /// Simple moving average of the most recent `signalPeriod` %K values — smoothed oscillator.
    /// Requires `period + signalPeriod - 1` history entries. No additional state needed.
    func stochasticD(period: Int = 14, signalPeriod: Int = 3) -> Double {
        let required = period + signalPeriod - 1
        guard sentimentHistory.count >= required else { return 0.5 }

        let history = Array(sentimentHistory.suffix(required))

        var kValues: [Double] = []
        for i in 0..<signalPeriod {
            let windowEnd = required - i
            let windowStart = windowEnd - period
            let window = Array(history[windowStart..<windowEnd])
            guard let minVal = window.min(), let maxVal = window.max() else { continue }
            let current = history[windowEnd - 1]
            let k = maxVal > minVal ? (current - minVal) / (maxVal - minVal) : 0.5
            kValues.append(k)
        }

        guard !kValues.isEmpty else { return 0.5 }
        return kValues.reduce(0, +) / Double(kValues.count)
    }

    // === Momentum (Raw Rate of Change) ===
    /// Point-to-point sentiment change over `period` interactions.
    /// Range: [-1, 1]. Positive = improved, negative = declined.
    /// Returns 0.0 on insufficient history (signed zero neutral, not 0.5).
    func momentum(period: Int = 10) -> Double {
        guard sentimentHistory.count >= period + 1 else { return 0.0 }
        let n = sentimentHistory.count
        return sentimentHistory[n - 1] - sentimentHistory[n - 1 - period]
    }

    // === Velocity (Momentum Acceleration — 2nd Derivative) ===
    /// Rate of change of momentum. Positive = momentum increasing (acceleration),
    /// negative = momentum decreasing (deceleration/reversal).
    /// Range: [-2, 2]. Returns 0.0 on insufficient history.
    func velocity(period: Int = 10) -> Double {
        guard sentimentHistory.count >= period + 2 else { return 0.0 }
        let n = sentimentHistory.count
        let currentMomentum = sentimentHistory[n - 1] - sentimentHistory[n - 1 - period]
        let previousMomentum = sentimentHistory[n - 2] - sentimentHistory[n - 2 - period]
        return currentMomentum - previousMomentum
    }

    // === Volume Weighted Average ===
    func volumeWeightedAverage(period: Int = 15) -> Double {
        guard sentimentHistory.count >= period else { return 0.5 }
        
        let recentSentiments = sentimentHistory.suffix(period)
        let recentLengths = responseLengthHistory.suffix(period)
        
        // Weight sentiment by response length (proxy for engagement volume)
        let weightedSum = zip(recentSentiments, recentLengths)
            .reduce(0.0) { $0 + ($1.0 * Double($1.1)) }
        
        let totalVolume = recentLengths.reduce(0, +)
        
        return totalVolume > 0 ? weightedSum / Double(totalVolume) : 0.5
    }
}
