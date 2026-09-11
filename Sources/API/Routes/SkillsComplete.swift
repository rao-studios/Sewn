//
//  SkillsComplete.swift
//  Sewn
//
//  ONE BOUNDED SKILL-INVOCATION SYNTHESIS, no persona, no Thread RAG, no
//  Gita contribution. Sibling of `/v1/complete`: that route flattens
//  messages into one user blob and ignores tools (corpus annotation).
//  This one keeps roles, offers the caller's tool roster, and may return
//  `tool_calls`. Mary's spoken lane stays on `/v1/chat/completions`.
//

import Foundation
import Hummingbird
import Logging

// MARK: - Wire models

struct SkillsCompleteMessage: Codable {
    let role: String
    let content: String
}

struct SkillsCompleteToolFunction: Codable {
    let name: String?
    let description: String?
    let parameters: JSONValue?
}

struct SkillsCompleteTool: Codable {
    let type: String?
    let function: SkillsCompleteToolFunction?
}

struct SkillsCompleteRequest: Codable {
    let instructions: String?
    let messages: [SkillsCompleteMessage]
    let tools: [SkillsCompleteTool]?
    let maxTokens: Int?
    let temperature: Float?
    /// Which backend synthesizes the invocation. Absent = the server default.
    let provider: LLMProvider?

    enum CodingKeys: String, CodingKey {
        case instructions, messages, tools, temperature, provider
        case maxTokens = "max_tokens"
    }
}

struct SkillsCompleteToolCall: Codable, Equatable {
    let name: String
    let arguments: String
}

struct SkillsCompleteResponse: Codable, ResponseEncodable {
    let text: String
    let toolCalls: [SkillsCompleteToolCall]?

    enum CodingKeys: String, CodingKey {
        case text
        case toolCalls = "tool_calls"
    }

    init(text: String, toolCalls: [SkillsCompleteToolCall]? = nil) {
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

func skillsCompleteSystemPrompt(instructions: String?) -> String? {
    guard let instructions, !instructions.isEmpty else { return nil }
    return instructions
}

/// Roles stay intact. Empty contents drop. The annotator's complete route
/// joins everything into one user blob; a skill round cannot survive that.
func skillsCompleteMessages(
    _ messages: [SkillsCompleteMessage]
) -> [Requests.Chat.Get.Message] {
    messages.compactMap { message in
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return .init(role: message.role, content: content)
    }
}

func skillsCompleteChatTools(
    _ tools: [SkillsCompleteTool]?
) -> [Requests.Chat.Get.Tool]? {
    guard let tools, !tools.isEmpty else { return nil }
    let mapped: [Requests.Chat.Get.Tool] = tools.compactMap { tool in
        guard let name = tool.function?.name, !name.isEmpty else { return nil }
        return .init(
            type: tool.type ?? "function",
            function: .init(
                name: name,
                description: tool.function?.description,
                parameters: tool.function?.parameters
            )
        )
    }
    return mapped.isEmpty ? nil : mapped
}

func skillsCompleteMaxTokens(_ requested: Int?) -> Int {
    min(max(requested ?? 800, 32), 2048)
}

/// When the provider returns prose instead of native tool_calls, recover
/// Mary's `<tool_call>{"name","arguments"}</tool_call>` form (and a bare
/// JSON object with those keys).
func skillsCompleteParseToolCalls(from text: String) -> [SkillsCompleteToolCall] {
    var calls: [SkillsCompleteToolCall] = []
    let tagged = try? NSRegularExpression(
        pattern: #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#,
        options: [.dotMatchesLineSeparators])
    let nsText = text as NSString
    let full = NSRange(location: 0, length: nsText.length)
    tagged?.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
        guard let match, match.numberOfRanges > 1,
              let json = jsonObject(from: nsText.substring(with: match.range(at: 1))),
              let call = skillCall(from: json)
        else { return }
        calls.append(call)
    }
    if calls.isEmpty, let json = jsonObject(from: text), let call = skillCall(from: json) {
        calls.append(call)
    }
    return calls
}

func skillsCompleteTextStrippingTags(_ text: String) -> String {
    let stripped = text.replacingOccurrences(
        of: #"<tool_call>[\s\S]*?</tool_call>"#,
        with: "",
        options: .regularExpression)
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func jsonObject(from text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{"),
          let end = trimmed.lastIndex(of: "}"), start < end
    else { return nil }
    let slice = String(trimmed[start...end])
    guard let data = slice.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
}

private func skillCall(from object: [String: Any]) -> SkillsCompleteToolCall? {
    guard let name = object["name"] as? String, !name.isEmpty else { return nil }
    let arguments: String
    if let text = object["arguments"] as? String {
        arguments = text
    } else if let nested = object["arguments"] {
        if let data = try? JSONSerialization.data(withJSONObject: nested),
           let text = String(data: data, encoding: .utf8) {
            arguments = text
        } else {
            arguments = "{}"
        }
    } else {
        arguments = "{}"
    }
    return SkillsCompleteToolCall(name: name, arguments: arguments)
}

// MARK: - Route registration

func registerSkillsCompleteRoute(
    _ router: some RouterMethods<SewnRequestContext>,
    modelProvider: ModelProvider
) {
    router.post("/v1/skills/complete") { request, context async throws -> SkillsCompleteResponse in
        let body = try await request.decode(as: SkillsCompleteRequest.self, context: context)

        let messages = skillsCompleteMessages(body.messages)
        guard !messages.isEmpty else {
            throw HTTPError(.badRequest, message: "messages is required")
        }

        let tools = skillsCompleteChatTools(body.tools)
        let maxTokens = skillsCompleteMaxTokens(body.maxTokens)
        context.logger.info(
            "[SkillsComplete] provider: \((body.provider ?? .serverDefault).rawValue), messages: \(messages.count), tools: \(tools?.count ?? 0), max_tokens: \(maxTokens)"
        )

        let provider = body.provider ?? .serverDefault
        let output: (text: String, toolCalls: [(name: String, arguments: String)])
        do {
            output = try await modelProvider.runWithTools(
                system: skillsCompleteSystemPrompt(instructions: body.instructions),
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                temperature: body.temperature ?? 0,
                provider: provider,
                logger: context.logger
            )
        } catch let error as ProviderUnavailable {
            context.logger.error("[SkillsComplete] provider unavailable: \(error)")
            throw HTTPError(.serviceUnavailable, message: error.description)
        } catch {
            context.logger.error("[SkillsComplete] upstream failure: \(error)")
            throw HTTPError(.badGateway, message: "skills complete model unavailable")
        }

        var calls = output.toolCalls.map {
            SkillsCompleteToolCall(name: $0.name, arguments: $0.arguments)
        }
        var text = output.text
        if calls.isEmpty {
            calls = skillsCompleteParseToolCalls(from: text)
            if !calls.isEmpty {
                text = skillsCompleteTextStrippingTags(text)
            }
        }
        return SkillsCompleteResponse(
            text: text,
            toolCalls: calls.isEmpty ? nil : calls)
    }
}
