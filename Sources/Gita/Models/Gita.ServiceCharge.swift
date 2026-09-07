//
//  Gita.ServiceCharge.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 4/13/26.
//

extension Gita {
    /// Defines how Sewn prices its service on top of the raw LLM token cost.
    ///
    /// The service charge covers: vector search infrastructure, Gita royalty
    /// computation, Oracle peer coordination, and server overhead.
    ///
    /// Two strategies are supported:
    /// - **fixed** — a flat credit amount per request.
    /// - **scaled** — a percentage of the LLM cost, optionally amplified by
    ///   surge pricing when server load is high (similar to Uber surge).
    ///
    /// Invariant:  `ownerPayouts.sum + serviceCharge == totalCost`
    struct ServiceChargeStrategy {
        // MARK: Pricing Modes

        enum Pricing {
            /// Flat credit fee per request, independent of LLM cost.
            case fixed(Credits)

            /// Percentage of the LLM cost, optionally scaled by server load.
            /// `baseRate` is a fraction, e.g. `0.20` == 20 %.
            case scaled(baseRate: Double, surge: SurgeParameters?)
        }

        // MARK: Surge Parameters

        /// Uber-style surge: service charge multiplier scales linearly with
        /// concurrent server load between 1× (idle) and `maxSurgeMultiplier` (peak).
        struct SurgeParameters {
            /// Number of concurrent requests that triggers maximum surge.
            let maxConcurrentLoad: Int
            /// Multiplier applied to the base rate at peak load (e.g. 2.5 == 250 %).
            let maxSurgeMultiplier: Double

            /// Returns the surge multiplier for `currentLoad` concurrent requests.
            func multiplier(currentLoad: Int) -> Double {
                let clamped = min(Double(currentLoad), Double(maxConcurrentLoad))
                let ratio   = clamped / Double(maxConcurrentLoad)
                // Linear interpolation from 1.0 (idle) → maxSurgeMultiplier (peak).
                // 1.15x @ 1, this additional 15% on top of the fixed base rate helps smooth out the initial ramp-up.
                return 1.0 + ratio * (maxSurgeMultiplier - 1.0)
            }
        }

        // MARK: Properties

        let pricing: Pricing

        // MARK: Presets

        /// Default strategy: 20 % service fee, surge up to 2.5× at 10 concurrent requests.
        static let `default` = ServiceChargeStrategy(
            pricing: .scaled(
                baseRate: 0.20,
                surge: SurgeParameters(maxConcurrentLoad: 10, maxSurgeMultiplier: 2.5)
            )
        )

        /// Flat fee preset — useful for testing or fixed-tier plans.
        static func flat(_ credits: Credits) -> ServiceChargeStrategy {
            ServiceChargeStrategy(pricing: .fixed(credits))
        }

        // MARK: Compute Charge

        /// Returns the service charge in credits for the given LLM cost and server load.
        func charge(llmCost: Credits, currentLoad: Int = 1) -> Credits {
            switch pricing {
            case .fixed(let credits):
                return credits
            case .scaled(let baseRate, let surge):
                let multiplier = surge?.multiplier(currentLoad: currentLoad) ?? 1.0
                return llmCost * baseRate * multiplier
            }
        }

        /// Returns the surge multiplier that was (or would be) applied for the given load.
        /// Always `1.0` for the `.fixed` pricing mode.
        func surgeMultiplier(currentLoad: Int = 1) -> Double {
            switch pricing {
            case .fixed:
                return 1.0
            case .scaled(_, let surge):
                return surge?.multiplier(currentLoad: currentLoad) ?? 1.0
            }
        }

        /// Returns the base service rate as a percentage string (e.g. `"20.0%"`).
        /// Returns `"fixed"` for the `.fixed` pricing mode.
        var baseRateDescription: String {
            switch pricing {
            case .fixed(let credits):
                return "fixed(\(CreditConversion.formattedCredits(credits)))"
            case .scaled(let baseRate, _):
                return String(format: "%.1f%%", baseRate * 100)
            }
        }

        /// Human-readable description of the active strategy.
        var strategyDescription: String {
            switch pricing {
            case .fixed(let credits):
                return "fixed(\(CreditConversion.formattedCredits(credits)))"
            case .scaled(let baseRate, let surge):
                if let surge {
                    return String(format: "scaled(%.0f%%, surge up to %.1f× at %d concurrent)",
                                  baseRate * 100, surge.maxSurgeMultiplier, surge.maxConcurrentLoad)
                } else {
                    return String(format: "scaled(%.0f%%, no surge)", baseRate * 100)
                }
            }
        }
    }
}