//
//  Gita+StreamBilling.swift
//  seer-server
//
//  Created by Ritesh Pakala on 4/12/26.
//

import Foundation

extension Gita {
    /// Billing utilities for the streaming response path.
    ///
    /// Mistral SSE does not return token counts in the stream, so this namespace
    /// centralises the estimation strategy and the full pricing pipeline.
    /// Adjust the heuristics here without touching the stream handler itself.
    ///
    /// Current strategy:
    ///   tokens ≈ UTF-8 byte count / `bytesPerToken`
    ///   Accuracy: ~±10 % for English text.
    enum StreamBilling {

        // MARK: - Estimation Heuristic

        /// Approximate UTF-8 bytes consumed per LLM token for English text.
        /// Adjust this constant (or replace with a real tokeniser) without
        /// touching any call site.
        static let bytesPerToken: Int = 4

        // MARK: - Token Estimation

        /// Extracts all message content from a `UserInput.Prompt` and
        /// estimates the prompt token count from the combined UTF-8 byte length.
        static func estimatedPromptTokens(from prompt: UserInput.Prompt) -> Int {
            let text: String = {
                switch prompt {
                case .messages(let msgs):
                    return msgs
                        .compactMap { $0[MessageProcessingKeys.content] as? String }
                        .joined(separator: " ")
                default:
                    return ""
                }
            }()
            return max(1, text.utf8.count / bytesPerToken)
        }

        /// Estimates the completion token count from the UTF-8 byte length
        /// of the fully accumulated response text.
        static func estimatedCompletionTokens(from text: String) -> Int {
            max(1, text.utf8.count / bytesPerToken)
        }

        // MARK: - Ledger Construction

        /// Builds a `TokenLedger` from estimated prompt and completion counts,
        /// then merges the optional Sinatra ledger (exact counts, not estimated).
        ///
        /// - Parameters:
        ///   - model: The primary generation model name (default: `"mistral-medium"`).
        ///   - prompt: The prompt sent to the streaming endpoint.
        ///   - completionText: The full accumulated response text.
        ///   - sinatraLedger: Optional ledger from Sinatra's sentiment call.
        ///                    When present, its exact token counts are merged in.
        static func buildLedger(
            model: String = "mistral-medium",
            prompt: UserInput.Prompt,
            completionText: String,
            sinatraLedger: Gita.TokenLedger? = nil
        ) -> Gita.TokenLedger {
            var ledger = Gita.TokenLedger()
            ledger.record(
                model: model,
                promptTokens:     estimatedPromptTokens(from: prompt),
                completionTokens: estimatedCompletionTokens(from: completionText)
            )
            if let sinatra = sinatraLedger {
                ledger.merge(sinatra)
            }
            return ledger
        }

        // MARK: - Full Billing Pipeline

        /// Runs the complete streaming billing pipeline and returns a priced
        /// `Gita.Contribution` ready to pass to `seer.accumulateEarnings(_:)`.
        ///
        /// 1. Awaits the concurrent Sinatra task (already running, zero latency).
        /// 2. Builds an estimated ledger and merges the exact Sinatra tokens.
        /// 3. Prices the contribution via `Gita.priceContribution`.
        ///
        /// Errors from the Sinatra task are swallowed — billing continues
        /// with primary-only cost rather than failing the response.
        ///
        /// - Parameters:
        ///   - contribution: The unpriced `Gita.Contribution` from search/retrieval.
        ///   - prompt: The prompt sent to the streaming endpoint (for estimation).
        ///   - accumulatedText: The full streamed response text (for estimation).
        ///   - sinatraLedger: The already-awaited ledger from `Sinatra.PrepareResult`, if any.
        ///                    The caller awaits the task before calling `price` so that
        ///                    `documentStatsUpdates` can also be extracted and persisted.
        ///   - gita: The `Gita` instance to call `priceContribution` on.
        ///   - strategy: Service charge strategy (default: `.default`).
        ///   - currentLoad: Current concurrent request count for surge calculation.
        ///   - request: Request context for log correlation.
        @discardableResult
        static func price(
            contribution: Gita.Contribution,
            prompt: UserInput.Prompt,
            accumulatedText: String,
            sinatraLedger: Gita.TokenLedger?,
            gita: Gita,
            strategy: ServiceChargeStrategy = .default,
            currentLoad: Int = 1,
            request: SeerRequest? = nil
        ) async -> Gita.Contribution {
            let ledger = buildLedger(
                prompt: prompt,
                completionText: accumulatedText,
                sinatraLedger: sinatraLedger
            )

            return gita.priceContribution(
                contribution,
                ledger: ledger,
                strategy: strategy,
                currentLoad: currentLoad,
                request: request
            )
        }
    }
}
