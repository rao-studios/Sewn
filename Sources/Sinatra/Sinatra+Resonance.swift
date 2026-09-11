//
//  Sinatra+Resonance.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 4/13/26.
//

import Foundation
import Logging

// MARK: - ResonancePartition

extension Sinatra {
    /// The distilled, embedded fragment of an assistant response that a user
    /// demonstrably resonated with. Stored in the user's "Resonance" group so
    /// future retrievals can surface content the user has already engaged with.
    struct ResonancePartition {
        /// Stable identifier derived from the resonant text — same SHA-256 + numeric-string
        /// strategy as `Sewn.computeNumericHash(from:)`.
        let documentId: String
        /// The exact verbatim excerpt from the assistant response that resonated.
        let text: String
        /// Embedding of `text`, ready to pass directly to `BatchPutItem`.
        let embeddingData: [EmbeddingData]
    }
}

// MARK: - LLM output model

extension Sinatra {
    struct ResonanceOutput: Decodable {
        let detected: Bool
        let excerpt: String
        let confidence: Double
    }
}

// MARK: - Resonance extraction

extension Sinatra {
    /// The stable group label for all resonance documents.
    static let resonanceGroupLabel: String = "Resonance"

    /// Minimum LLM confidence required to accept an excerpt as genuinely resonant.
    /// Below this threshold, extraction is treated as a miss and training is skipped.
    static let resonanceConfidenceThreshold: Double = 0.55

    /// Identifies which specific passage in the assistant response the user most
    /// resonated with, then embeds it for later storage in the "Resonance" group.
    ///
    /// Returns `(nil, ledger)` when:
    ///  - the LLM reports no detectable resonance or confidence is below threshold,
    ///  - the extracted excerpt cannot be verified as a verbatim substring of the
    ///    assistant response (hallucination guard),
    ///  - or the embedding call fails.
    ///
    /// The `ledger` captures the internal LLM cost regardless of whether a
    /// partition was produced, so the caller can always include it in billing.
    func extractResonance(
        userContent: String,
        assistantContent: String,
        request: SewnRequest,
        modelProvider: ModelProvider,
        provider: LLMProvider = .serverDefault
    ) async throws -> (partition: ResonancePartition?, ledger: Gita.TokenLedger) {

        var ledger = Gita.TokenLedger()

        let prompt: String = """
        **Assistant Response:**
        \(assistantContent)

        **User Reply:**
        \(userContent)

        Identify the exact passage from the assistant response that the user resonated with.
        Provide the JSON output as specified.
        """

        let systemPrompt: String = """
        You are a resonance detector. Given an assistant response and the user's reply, \
        identify the specific passage the user most clearly engaged with.

        OUTPUT RULES — follow exactly:
        1. Output a single JSON object only. No markdown fences, no prose before or after.
        2. All three keys must be present in every response.
        3. "detected" must be the literal true or false (no quotes).
        4. "excerpt" must be an EXACT, verbatim substring from the assistant response — never \
        paraphrase or summarize. Use an empty string when detected is false.
        5. "confidence" must be a JSON number 0.0–1.0 (no quotes, no range notation).
        6. No trailing commas. No comments inside the JSON.

        SCHEMA:
        "detected"   — boolean: true only when the user's reply contains a traceable link to
                        a specific passage in the assistant response (direct engagement, emotional
                        reaction, follow-up, or extension of a specific idea)
        "excerpt"    — string: the exact verbatim passage (1–3 sentences) from the assistant
                        response that the user engaged with; "" when detected is false
        "confidence" — number 0.0–1.0

        Set detected: false when the user's reply is generic praise, small-talk, or contains no
        traceable reference to a specific assistant passage.

        EXAMPLE OUTPUT (values are illustrative only):
        {"detected":true,"excerpt":"The key insight here is that repetition creates familiarity.","confidence":0.87}
        """

        logger.debug(
            "Resonance",
            "⚜️ 🫀 Sending resonance prompt to LLM (maxTokens=400)",
            service: .sinatra,
            request: request
        )

        let (rawOutput, usage) = try await modelProvider.run(
            prompt,
            systemPrompt: systemPrompt,
            maxTokens: 400,
            temperature: 0.05,
            provider: provider,
            logger: logger.base
        )
        ledger.record(
            model: "mistral-tiny",
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens
        )

        let output = (rawOutput ?? "").strippingMarkdownFences()
        guard let jsonData = cleanLLMJSON(output).data(using: .utf8),
              let result = try? JSONDecoder().decode(ResonanceOutput.self, from: jsonData) else {
            logger.warning(
                "⚜️ 🫀 [Resonance] Failed to decode resonance JSON — raw: \(output.prefix(200))",
                service: .sinatra,
                request: request,
                flow: .chat
            )
            return (nil, ledger)
        }

        guard result.detected,
              result.confidence >= Self.resonanceConfidenceThreshold,
              !result.excerpt.isEmpty else {
            logger.info(
                "Resonance",
                "⚜️ 🫀 No resonance detected (detected=\(result.detected) confidence=\(String(format: "%.2f", result.confidence))) — training gate closed",
                service: .sinatra,
                request: request,
                flow: .chat
            )
            return (nil, ledger)
        }

        // Hallucination guard: the excerpt must appear verbatim in the assistant response.
        // High-confidence rejections here are worth monitoring — they indicate the LLM
        // is paraphrasing or normalising whitespace/punctuation rather than copying verbatim.
        guard assistantContent.contains(result.excerpt) else {
            let isHighConfidence = result.confidence >= 0.75
            let excerptHead  = result.excerpt.prefix(120)
            let assistantHead = assistantContent.prefix(80)
            if isHighConfidence {
                let msg: Logger.Message = "⚜️ 🫀 [Resonance] HIGH-CONFIDENCE hallucination-guard rejection (confidence=\(String(format: "%.2f", result.confidence))) — excerpt not found verbatim. excerpt_head=\"\(excerptHead)\" assistant_head=\"\(assistantHead)\""
                logger.warning(msg, service: .sinatra, request: request, flow: .chat)
            } else {
                let msg: Logger.Message = "⚜️ 🫀 [Resonance] Hallucination-guard rejection (confidence=\(String(format: "%.2f", result.confidence))) — excerpt not found verbatim. excerpt_head=\"\(excerptHead)\""
                logger.warning(msg, service: .sinatra, request: request, flow: .chat)
            }
            return (nil, ledger)
        }

        // Embed the resonant excerpt via the API embedding model.
        let embeddingData: [EmbeddingData]
        do {
            embeddingData = try await StandaloneGeneration.runAPIEmbedding(
                [result.excerpt],
                logger: logger.base
            )
        } catch {
            logger.warning(
                "⚜️ 🫀 [Resonance] Embedding failed for resonance excerpt — training gate closed: \(error)",
                service: .sinatra,
                request: request,
                flow: .chat
            )
            return (nil, ledger)
        }

        let documentId = Sewn.computeNumericHash(from: result.excerpt)
        let partition = ResonancePartition(
            documentId: documentId,
            text: result.excerpt,
            embeddingData: embeddingData
        )

        logger.info(
            "Resonance",
            "⚜️ 🫀 Resonance partition extracted (docId=\(documentId) confidence=\(String(format: "%.2f", result.confidence))): \"\(result.excerpt.prefix(120))\"",
            service: .sinatra,
            request: request,
            flow: .frank(partitionId: documentId)
        )

        return (partition, ledger)
    }

}

// MARK: - String helper (file-scoped)

private extension String {
    /// Strips leading/trailing markdown code fences (``` or ```json etc.)
    /// and surrounding whitespace from LLM output before JSON decoding.
    func strippingMarkdownFences() -> String {
        var result = self
        if let range = result.range(of: "^```[a-zA-Z]*\\n?", options: .regularExpression) {
            result.removeSubrange(range)
        }
        if let range = result.range(of: "\\n?```$", options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
