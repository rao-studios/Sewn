//
//  CodeComplete.swift
//  Seer
//
//  ONE BOUNDED CODING-INVOCATION SYNTHESIS, no persona, no Totem RAG, no
//  Gita. Sibling of `/v1/skills/complete`: that route is Mary's ability
//  roster. This one is the pair-coding file-tool roster. Mary never sends
//  a model id — `ModelConfig.codingModel` is Seer's pin (Codestral by default).
//

import Foundation
import Hummingbird
import Logging

typealias CodeCompleteRequest = SkillsCompleteRequest
typealias CodeCompleteResponse = SkillsCompleteResponse

func codeCompleteMaxTokens(_ requested: Int?) -> Int {
    min(max(requested ?? 2048, 32), 4096)
}

func registerCodeCompleteRoute(
    _ router: some RouterMethods<SeerRequestContext>,
    modelProvider: ModelProvider
) {
    router.post("/v1/code/complete") { request, context async throws -> CodeCompleteResponse in
        let body = try await request.decode(as: CodeCompleteRequest.self, context: context)

        let messages = skillsCompleteMessages(body.messages)
        guard !messages.isEmpty else {
            throw HTTPError(.badRequest, message: "messages is required")
        }

        let tools = skillsCompleteChatTools(body.tools)
        let maxTokens = codeCompleteMaxTokens(body.maxTokens)
        let model = ModelConfig.codingModel
        context.logger.info(
            "[CodeComplete] model: \(model), messages: \(messages.count), tools: \(tools?.count ?? 0), max_tokens: \(maxTokens)"
        )

        let output: (text: String, toolCalls: [(name: String, arguments: String)])
        do {
            output = try await modelProvider.runWithTools(
                system: skillsCompleteSystemPrompt(instructions: body.instructions),
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                temperature: body.temperature ?? 0,
                model: model,
                logger: context.logger
            )
        } catch {
            context.logger.error("[CodeComplete] upstream failure: \(error)")
            throw HTTPError(.badGateway, message: "code complete model unavailable")
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
