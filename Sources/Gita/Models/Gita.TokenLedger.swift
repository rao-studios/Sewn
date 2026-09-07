//
//  Gita.TokenCost.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 4/12/26.
//

import Foundation

// MARK: - Credits

extension Gita {
    /// Sewn's internal billing unit.
    /// Conversion: $0.10 USD == 10 credits  →  1 credit == $0.01 USD
    /// Use `CreditConversion` to move between credits and fiat.
    typealias Credits = Double
}

// MARK: - Credit Conversion

extension Gita {
    enum CreditConversion {
        /// How many credits equal one US dollar.
        /// $0.10 == 10 credits  →  $1.00 == 100 credits.
        static let creditsPerDollar: Double = 100.0

        static func toDollars(_ credits: Credits) -> Double {
            credits / creditsPerDollar
        }

        static func fromDollars(_ dollars: Double) -> Credits {
            dollars * creditsPerDollar
        }

        static func formattedCredits(_ credits: Credits) -> String {
            String(format: "%.4fcr", credits)
        }

        static func formattedDollars(_ credits: Credits) -> String {
            String(format: "$%.6f", toDollars(credits))
        }
    }
}

// MARK: - Model Pricing

extension Gita {
    /// Per-token cost for a single LLM model, expressed in Credits.
    struct ModelPricing {
        let promptCreditsPerToken: Credits
        let completionCreditsPerToken: Credits

        /// Compute total credit cost for a prompt+completion usage pair.
        func cost(promptTokens: Int, completionTokens: Int) -> Credits {
            (Double(promptTokens) * promptCreditsPerToken)
                + (Double(completionTokens) * completionCreditsPerToken)
        }
    }

    /// Static pricing catalog.
    /// Add a new entry here whenever a new model is introduced to the Sewn network.
    /// Prices are sourced from provider list pricing and converted to credits.
    enum ModelCatalog {
        // Mistral pricing as of 2026-04 (per-token, converted from USD):
        //   mistral-medium  — $3.00 / 1M prompt,  $9.00 / 1M completion
        //   mistral-small   — $1.00 / 1M prompt,  $3.00 / 1M completion
        //   mistral-tiny    — $0.25 / 1M prompt,  $0.25 / 1M completion
        static let pricing: [String: ModelPricing] = [
            "mistral-medium": .init(
                promptCreditsPerToken:     CreditConversion.fromDollars(3.00) / 1_000_000,
                completionCreditsPerToken: CreditConversion.fromDollars(9.00) / 1_000_000
            ),
            // Sewn's default chat model (see ModelConfig.defaultModel) —
            // same rate as "mistral-medium", priced explicitly rather than
            // relying on the catalog's medium-rate fallback.
            "mistral-medium-latest": .init(
                promptCreditsPerToken:     CreditConversion.fromDollars(3.00) / 1_000_000,
                completionCreditsPerToken: CreditConversion.fromDollars(9.00) / 1_000_000
            ),
            "mistral-small": .init(
                promptCreditsPerToken:     CreditConversion.fromDollars(1.00) / 1_000_000,
                completionCreditsPerToken: CreditConversion.fromDollars(3.00) / 1_000_000
            ),
            "mistral-tiny": .init(
                promptCreditsPerToken:     CreditConversion.fromDollars(0.25) / 1_000_000,
                completionCreditsPerToken: CreditConversion.fromDollars(0.25) / 1_000_000
            ),
            // ThinkingMachines (Tinker) sampling has no published per-token list
            // price yet; billed at mistral-small-equivalent rates until it does.
            "thinkingmachines/Inkling": .init(
                promptCreditsPerToken:     CreditConversion.fromDollars(1.00) / 1_000_000,
                completionCreditsPerToken: CreditConversion.fromDollars(3.00) / 1_000_000
            ),
        ]

        /// Returns pricing for the given model identifier, falling back to
        /// `mistral-medium` rates if the model is not in the catalog.
        /// Fine-tuned Tinker checkpoints (`tinker://…`) bill at inkling rates.
        static func pricing(for model: String) -> ModelPricing {
            if let exact = pricing[model] { return exact }
            if model.hasPrefix("tinker://") { return pricing["thinkingmachines/Inkling"]! }
            return pricing["mistral-medium"]!
        }
    }
}

// MARK: - Token Ledger

extension Gita {
    /// Accumulates token usage across **all** LLM calls made during a single
    /// HTTP request. A single chat request may invoke the model multiple times
    /// (primary completion, auto-memory summarization, Sinatra scoring, etc.).
    /// Each call is appended as a `Line`; totals roll up automatically.
    ///
    /// Usage:
    /// ```swift
    /// var ledger = Gita.TokenLedger()
    /// ledger.record(model: "mistral-medium", promptTokens: result.usage.promptTokens,
    ///               completionTokens: result.usage.completionTokens)
    /// ```
    struct TokenLedger: Codable {
        struct Line: Codable {
            let model: String
            let promptTokens: Int
            let completionTokens: Int
            /// Pre-computed credit cost for this single call.
            let credits: Credits

            enum CodingKeys: String, CodingKey {
                case model
                case promptTokens     = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case credits
            }
        }

        private(set) var lines: [Line] = []

        var totalPromptTokens: Int     { lines.reduce(0) { $0 + $1.promptTokens } }
        var totalCompletionTokens: Int { lines.reduce(0) { $0 + $1.completionTokens } }
        var totalTokens: Int           { totalPromptTokens + totalCompletionTokens }
        var totalCredits: Credits      { lines.reduce(0) { $0 + $1.credits } }

        /// Record one LLM call's token usage. Credit cost is computed automatically
        /// from the `ModelCatalog`.
        mutating func record(model: String, promptTokens: Int, completionTokens: Int) {
            let pricing = ModelCatalog.pricing(for: model)
            let credits = pricing.cost(
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
            lines.append(.init(
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                credits: credits
            ))
        }

        var isEmpty: Bool { lines.isEmpty }

        /// Merges all lines from `other` into this ledger.
        /// Use this to combine token costs from concurrent LLM calls
        /// (e.g. primary generation + Sinatra sentiment analysis) into a single ledger
        /// before passing to `priceContribution`.
        mutating func merge(_ other: TokenLedger) {
            lines.append(contentsOf: other.lines)
        }

        var debugDescription: String {
            var desc = "Token Ledger (\(lines.count) call\(lines.count == 1 ? "" : "s")):\n"
            for line in lines {
                desc += "  [\(line.model)]"
                desc += "  prompt=\(line.promptTokens)"
                desc += "  completion=\(line.completionTokens)"
                desc += "  → \(CreditConversion.formattedCredits(line.credits))"
                desc += " (\(CreditConversion.formattedDollars(line.credits)))\n"
            }
            desc += "  ─────────────────────────────────────────\n"
            desc += "  Total \(totalTokens) tokens"
            desc += "  → \(CreditConversion.formattedCredits(totalCredits))"
            desc += " (\(CreditConversion.formattedDollars(totalCredits)))"
            return desc
        }

        enum CodingKeys: String, CodingKey {
            case lines
        }
    }
}
