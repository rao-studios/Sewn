import Foundation
import Logging
import Metrics

final class ModelProvider {
    private let logger: Logger
    private let fileManager = FileManager.default
    private let network: NetworkService
    /// Utility one-shots always run on the Mistral API; primary chat routes
    /// here too whenever the resolved model is Mistral-family (see
    /// `ModelConfig.isMistralModel`), and to `network` (Tinker) otherwise.
    private let mistralNetwork: NetworkService

    init(logger: Logger) {
        self.logger = logger
        self.network = NetworkService(logger: logger)
        self.mistralNetwork = NetworkService(logger: logger, base: .mistral)

        guard FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first != nil else {
            fatalError("Could not find documents directory")
        }
    }

    /// Runs a standalone generation against the global LLM — Mistral's
    /// chat-completions API or ThinkingMachines' Anthropic-compatible
    /// Messages API, chosen by the resolved model's provider family.
    ///
    /// A leading/trailing `system`-role message in the prompt is hoisted out
    /// of `messages` and re-attached per provider: Anthropic's top-level
    /// `system` field, or an inline leading system message for Mistral.
    /// - Returns: The generation, first choice as a chat completion result.
    func run(
        _ prompt: UserInput.Prompt,
        generationParameters: ChatGenerationParameters,
        maxTokens: Int? = nil,
        model: String? = nil,
        logger: Logger
    ) async throws -> (
        choices: [ChatCompletionChoice],
        usage: Requests.Chat.Get.Usage) {
        var system: String?
        var messages: [Requests.Messages.Create.Message] = []
        switch prompt {
        case .messages(let generatedMessages):
            for message in generatedMessages {
                if let roleValue = message[MessageProcessingKeys.role] as? String,
                   let contentValue = message[MessageProcessingKeys.content] as? String,
                   contentValue.isEmpty == false {
                    if roleValue == ChatMessageRequestRole.system.rawValue {
                        system = [system, contentValue].compactMap { $0 }.joined(separator: "\n\n")
                    } else {
                        messages.append(.init(role: roleValue, content: contentValue))
                    }
                }
            }
        default:
            break
        }

        logger.info("⚜️ Sending messages: \(messages.count)")

        let resolvedModel = ModelConfig.resolveChatModel(requested: model)
        let resolvedMaxTokens = ModelConfig.chatMaxTokens(
            requested: maxTokens ?? generationParameters.maxTokens,
            model: resolvedModel)
        let llmStart = Date()
        defer {
            SeerMetrics.llmDuration.recordMilliseconds(Date().timeIntervalSince(llmStart) * 1000)
            Counter(label: "provider.llm_requests_total", dimensions: [("model", resolvedModel)]).increment()
        }

        if ModelConfig.isMistralModel(resolvedModel) {
            // Mistral chat-completions: system rides inline as a leading
            // message rather than a top-level field.
            var mistralMessages: [Requests.Chat.Get.Message] = []
            if let system {
                mistralMessages.append(.init(role: ChatMessageRequestRole.system.rawValue, content: system))
            }
            mistralMessages.append(contentsOf: messages.map {
                .init(role: $0.role, content: $0.content)
            })
            let response = try await mistralNetwork.request(
                Requests.Chat.Get(
                    model: resolvedModel,
                    messages: mistralMessages,
                    maxTokens: resolvedMaxTokens,
                    temperature: generationParameters.temperature,
                    topP: generationParameters.topP
                )
            )
            let choice = response.choices.first
            let choices: [ChatCompletionChoice] = [
                .init(
                    index: 0,
                    message: .init(
                        role: choice?.message.role ?? "assistant",
                        content: choice?.message.content ?? ""),
                    finishReason: choice?.finishReason ?? "stop"
                )
            ]
            return (choices, response.usage)
        }

        let response = try await network.request(
            Requests.Messages.Create(
                model: resolvedModel,
                system: system,
                messages: messages,
                maxTokens: resolvedMaxTokens,
                temperature: generationParameters.temperature,
                topP: generationParameters.topP
            )
        )

        let choices: [ChatCompletionChoice] = [
            .init(
                index: 0,
                message: .init(
                    role: response.role,
                    content: response.text),
                finishReason: response.stopReason ?? "stop"
            )
        ]

        return (choices, response.usage.asChatUsage)
    }

    /// Runs a standalone one-shot generation against the global LLM.
    ///
    /// Returns both the generated text and the token usage for that call so
    /// callers can record the cost in a `Gita.TokenLedger`.
    func run(
        _ prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        model preferredModel: String? = nil,
        logger: Logger
    ) async throws -> (content: String?, usage: Requests.Chat.Get.Usage) {
        logger.info("Sending chat request via Model Provider.")

        let model = preferredModel ?? ModelConfig.utilityModel
        let llmStart = Date()
        defer {
            SeerMetrics.llmDuration.recordMilliseconds(Date().timeIntervalSince(llmStart) * 1000)
            Counter(label: "provider.llm_requests_total", dimensions: [("model", model)]).increment()
        }

        if ModelConfig.isMistralModel(model) {
            var messages: [Requests.Chat.Get.Message] = []
            if let systemPrompt {
                messages.append(.init(role: ChatMessageRequestRole.system.rawValue, content: systemPrompt))
            }
            messages.append(.init(role: ChatMessageRequestRole.user.rawValue, content: prompt))
            let response = try await mistralNetwork.request(
                Requests.Chat.Get(
                    model: model,
                    messages: messages,
                    maxTokens: maxTokens ?? GenerationDefaults.maxTokens,
                    temperature: temperature ?? GenerationDefaults.temperature,
                    topP: GenerationDefaults.topP
                )
            )
            let text = response.choices.first?.message.content ?? ""
            return (text.isEmpty ? "Unknown" : text, response.usage)
        }

        // Non-Mistral utility override (e.g. a Tinker model): suppress Qwen3
        // deliberation, keep the thinking-token floor.
        let utilityPrompt = ModelConfig.supportsNoThinkSwitch(model)
            ? prompt + " /no_think" : prompt
        let response = try await network.request(
            Requests.Messages.Create(
                model: model,
                system: systemPrompt,
                messages: [.init(role: ChatMessageRequestRole.user.rawValue, content: utilityPrompt)],
                maxTokens: ModelConfig.chatMaxTokens(requested: maxTokens, model: model),
                temperature: temperature ?? GenerationDefaults.temperature,
                topP: GenerationDefaults.topP
            )
        )
        let text = response.text
        return (text.isEmpty ? "Unknown" : text, response.usage.asChatUsage)
    }

    /// Runs a one-shot generation that must return structured data: the model is
    /// forced to call a single tool whose `input_schema` is `schema`, and the
    /// tool input is decoded as `T`. Replaces prompt-and-parse for internal
    /// pipelines (Sinatra sentiment, etc.).
    func runStructured<T: Decodable>(
        _ prompt: String,
        systemPrompt: String? = nil,
        toolName: String,
        toolDescription: String? = nil,
        schema: JSONValue,
        maxTokens: Int? = nil,
        logger: Logger
    ) async throws -> (value: T, usage: Requests.Chat.Get.Usage) {
        let model = ModelConfig.utilityModel
        let llmStart = Date()
        defer {
            SeerMetrics.llmDuration.recordMilliseconds(Date().timeIntervalSince(llmStart) * 1000)
            Counter(label: "provider.llm_requests_total", dimensions: [("model", model)]).increment()
        }

        if ModelConfig.isMistralModel(model) {
            // Mistral path: schema-in-prompt + strict JSON parse (mistral-tiny
            // has no function calling; prompt-and-parse matches the pre-Tinker
            // behavior of these internal pipelines).
            let schemaText: String = {
                guard let data = try? JSONEncoder().encode(schema),
                      let text = String(data: data, encoding: .utf8) else { return "{}" }
                return text
            }()
            var system = systemPrompt.map { $0 + "\n\n" } ?? ""
            system += """
            Respond with ONLY a single JSON object for `\(toolName)`\(toolDescription.map { " (\($0))" } ?? "") \
            that matches this JSON schema exactly. No prose, no code fences, no explanations.
            Schema: \(schemaText)
            """
            let response = try await mistralNetwork.request(
                Requests.Chat.Get(
                    model: model,
                    messages: [
                        .init(role: ChatMessageRequestRole.system.rawValue, content: system),
                        .init(role: ChatMessageRequestRole.user.rawValue, content: prompt),
                    ],
                    maxTokens: maxTokens ?? GenerationDefaults.maxTokens,
                    temperature: 0
                )
            )
            let content = response.choices.first?.message.content ?? ""
            guard let first = content.firstIndex(of: "{"),
                  let last = content.lastIndex(of: "}"), first < last,
                  let data = String(content[first...last]).data(using: .utf8)
            else {
                throw NetworkService.NetworkError.invalidResponse
            }
            let value = try JSONDecoder().decode(T.self, from: data)
            return (value, response.usage)
        }

        // Non-Mistral utility override: Anthropic-style forced tool call.
        let utilityPrompt = ModelConfig.supportsNoThinkSwitch(model)
            ? prompt + " /no_think" : prompt
        let response = try await network.request(
            Requests.Messages.Create(
                model: model,
                system: systemPrompt,
                messages: [.init(role: ChatMessageRequestRole.user.rawValue, content: utilityPrompt)],
                // Same thinking floor as run(_:) — the tool_use block only
                // arrives after the model finishes reasoning.
                maxTokens: ModelConfig.chatMaxTokens(requested: maxTokens, model: model),
                temperature: 0,
                tools: [.init(name: toolName, description: toolDescription, inputSchema: schema)],
                toolChoice: .tool(toolName)
            )
        )
        guard let input = response.toolUse?.input else {
            throw NetworkService.NetworkError.invalidResponse
        }
        let data = try JSONEncoder().encode(input)
        let value = try JSONDecoder().decode(T.self, from: data)
        return (value, response.usage.asChatUsage)
    }

    /// One non-streaming generation that may return native tool calls.
    /// Used by `/v1/skills/complete` — not chat, not the annotator.
    func runWithTools(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        maxTokens: Int,
        temperature: Float,
        model preferredModel: String? = nil,
        logger: Logger
    ) async throws -> (text: String, toolCalls: [(name: String, arguments: String)]) {
        let resolvedModel = ModelConfig.resolveChatModel(requested: preferredModel)
        let resolvedMaxTokens = ModelConfig.chatMaxTokens(
            requested: maxTokens, model: resolvedModel)
        let llmStart = Date()
        defer {
            SeerMetrics.llmDuration.recordMilliseconds(Date().timeIntervalSince(llmStart) * 1000)
            Counter(label: "provider.llm_requests_total", dimensions: [("model", resolvedModel)]).increment()
        }

        if ModelConfig.isMistralModel(resolvedModel) {
            var mistralMessages: [Requests.Chat.Get.Message] = []
            if let system, !system.isEmpty {
                mistralMessages.append(.init(
                    role: ChatMessageRequestRole.system.rawValue, content: system))
            }
            mistralMessages.append(contentsOf: messages)
            let response = try await mistralNetwork.request(
                Requests.Chat.Get(
                    model: resolvedModel,
                    messages: mistralMessages,
                    maxTokens: resolvedMaxTokens,
                    temperature: temperature,
                    tools: tools
                )
            )
            let message = response.choices.first?.message
            let text = message?.content ?? ""
            let calls = (message?.toolCalls ?? []).compactMap { call -> (String, String)? in
                guard let name = call.function?.name, !name.isEmpty else { return nil }
                return (name, call.function?.arguments ?? "{}")
            }
            return (text, calls)
        }

        var anthropicMessages: [Requests.Messages.Create.Message] = []
        for message in messages {
            guard !message.content.isEmpty else { continue }
            if message.role == ChatMessageRequestRole.system.rawValue { continue }
            anthropicMessages.append(.init(role: message.role, content: message.content))
        }
        let anthropicTools = tools?.compactMap { tool -> Requests.Messages.Create.Tool? in
            let name = tool.function.name
            guard !name.isEmpty else { return nil }
            return .init(
                name: name,
                description: tool.function.description,
                inputSchema: tool.function.parameters ?? .object([:]))
        }
        let response = try await network.request(
            Requests.Messages.Create(
                model: resolvedModel,
                system: system,
                messages: anthropicMessages,
                maxTokens: resolvedMaxTokens,
                temperature: temperature,
                tools: anthropicTools,
                toolChoice: anthropicTools == nil ? nil : .auto
            )
        )
        let calls = response.toolUses.compactMap { block -> (String, String)? in
            guard let name = block.name, !name.isEmpty else { return nil }
            return (name, block.input?.jsonString() ?? "{}")
        }
        return (response.text, calls)
    }
}
