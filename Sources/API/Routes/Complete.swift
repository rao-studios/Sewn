//
//  Complete.swift
//  Seer
//
//  ONE BOUNDED GENERATION, no persona, no Totem RAG, no Gita contribution.
//  `/v1/chat/completions` always runs `_processUserMessages` — personality,
//  HNSW retrieval, auto_memory, and a trailing contribution chunk. Jobs that
//  need a JSON object and nothing else (corpus unit annotation today,
//  structured tool use later) cannot survive that pipeline: the model
//  answers in prose about the file and the caller parses nothing.
//
//  Sibling of `/v1/vision/look`: one POST, one JSON body, no SSE trailer.
//  The chat model is called the way vision calls Pixtral — system + user,
//  one completion. There is no `seer` scope object on the wire.
//

import Foundation
import Hummingbird
import Logging

// MARK: - Wire models

struct CompleteMessage: Codable {
    let role: String
    let content: String
}

/// OpenAI-style tool declaration. Accepted and unused by this handler —
/// reserved so a later caller can offer tools without a second route.
struct CompleteTool: Codable {
    let type: String?
    let function: CompleteToolFunction?
}

struct CompleteToolFunction: Codable {
    let name: String?
    let description: String?
}

struct CompleteRequest: Codable {
    let instructions: String?
    let messages: [CompleteMessage]
    let tools: [CompleteTool]?
    let maxTokens: Int?
    let temperature: Float?

    enum CodingKeys: String, CodingKey {
        case instructions, messages, tools, temperature
        case maxTokens = "max_tokens"
    }
}

struct CompleteToolCall: Codable, Equatable {
    let name: String
    let arguments: String
}

struct CompleteResponse: Codable, ResponseEncodable {
    let text: String
    let toolCalls: [CompleteToolCall]?

    enum CodingKeys: String, CodingKey {
        case text
        case toolCalls = "tool_calls"
    }

    init(text: String, toolCalls: [CompleteToolCall]? = nil) {
        self.text = text
        self.toolCalls = toolCalls
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if let toolCalls, !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
    }
}

// MARK: - Prompt construction (free functions so tests can pin the wording)

/// The system prompt is the caller's instructions, unadorned. Wrapping them
/// in a persona is the failure `/v1/chat/completions` exists to perform and
/// this route exists to refuse.
func completeSystemPrompt(instructions: String?) -> String? {
    guard let instructions, !instructions.isEmpty else { return nil }
    return instructions
}

/// User-side text: message contents in order, nothing retrieved, nothing
/// contributed. Assistant turns stay in the transcript so a later tool-
/// using caller can round-trip; the annotator sends one user message.
func completeUserText(messages: [CompleteMessage]) -> String {
    messages
        .map(\.content)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

/// A thinking utility model (Inkling, a tinker checkpoint) deliberates for
/// 30–90s per call. Corpus annotation is a JSON object of one sentence and
/// a handful of labels — routing it through that model made every unit
/// look like "the summariser returned nothing" on Mary's client timeout.
func completeGenerationModel(_ utility: String) -> String {
    ModelConfig.isThinkingModel(utility) ? ModelConfig.defaultUtilityModel : utility
}

/// The DEFAULT stays tight — annotation asks for a JSON object, not a page,
/// and every unit in a corpus pass pays for whatever this route grants.
///
/// THE CEILING IS NOT THE DEFAULT. Annotation is no longer the only caller:
/// Ability Studio's skill drafter asks this route for a whole recipe, and an
/// eight-step object does not fit in 512. A budget the caller states
/// explicitly is honoured up to `skillsCompleteMaxTokens`'s ceiling, because
/// a truncated JSON object is not a short answer — it is an unparsable one,
/// and the caller cannot tell which it got.
func completeMaxTokens(_ requested: Int?) -> Int {
    min(max(requested ?? 256, 32), 2048)
}

// MARK: - Route registration

func registerCompleteRoute(
    _ router: some RouterMethods<SeerRequestContext>,
    modelProvider: ModelProvider
) {
    router.post("/v1/complete") { request, context async throws -> CompleteResponse in
        let body = try await request.decode(as: CompleteRequest.self, context: context)

        guard !body.messages.isEmpty else {
            throw HTTPError(.badRequest, message: "messages is required")
        }
        let userText = completeUserText(messages: body.messages)
        guard !userText.isEmpty else {
            throw HTTPError(.badRequest, message: "messages must carry content")
        }

        context.logger.info(
            "[Complete] messages: \(body.messages.count), tools: \(body.tools?.count ?? 0), max_tokens: \(completeMaxTokens(body.maxTokens))"
        )

        let output: String
        do {
            let utility = ModelConfig.utilityModel
            let model = completeGenerationModel(utility)
            output = try await StandaloneGeneration.runLLM(
                userText,
                systemPrompt: completeSystemPrompt(instructions: body.instructions),
                maxTokens: completeMaxTokens(body.maxTokens),
                temperature: body.temperature ?? 0,
                model: model,
                modelProvider: modelProvider,
                logger: context.logger
            ) ?? ""
        } catch {
            context.logger.error("[Complete] upstream failure: \(error)")
            throw HTTPError(.badGateway, message: "complete model unavailable")
        }

        // Tools are accepted on the wire and unused here: no tool_calls.
        return CompleteResponse(text: output)
    }
}
