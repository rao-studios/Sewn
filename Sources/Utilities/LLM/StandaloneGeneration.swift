//
//  Generate.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/28/25.
//

import Foundation
import Logging

/// A helper class to run standalone generations with a prompt.
/// helpful for 1 off customizable prompts to manipulate strings
/// such as sanitization or regex cases.
class StandaloneGeneration {
    
    /// Runs a standalone generation on a default loaded LLM.
    /// - Parameters:
    ///   - prompt: The prompt
    ///   - modelProvider: The modelProvider
    ///   - logger: The logger
    /// - Returns: The generation, first choice as a chat completion result
    static func runLLM(
        _ prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        model: String? = nil,
        provider: LLMProvider = .serverDefault,
        modelProvider: ModelProvider,
        logger: Logger
    ) async throws -> String? {
        // A ROUTE THE CLIENT CALLED. `/v1/complete` and `/v1/tools/summarize`
        // are asked for; they are not the background passes the on-device gate
        // exists to hold back.
        return try await modelProvider.run(
            prompt, systemPrompt: systemPrompt, maxTokens: maxTokens,
            temperature: temperature, model: model, provider: provider,
            background: false, logger: logger
        ).content
    }
    
    /// Runs a standalone generation on a API based LLM (Mistral).
    /// - Parameters:
    ///   - prompt: The prompt
    ///   - systemPrompt: Optional system prompt
    ///   - maxTokens: Max tokens to generate
    ///   - temperature: Sampling temperature. Lower → more deterministic output.
    ///   - topP: Nucleus sampling threshold.
    ///   - repetitionPenalty: Penalty applied to already-seen tokens. > 1.0 discourages repetition.
    ///   - repetitionContextSize: Number of prior tokens examined when applying the repetition penalty.
    ///   - logger: The logger
    /// - Returns: The generation, first choice as a chat completion result
    static func runAPILLM(
        _ prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Float = GenerationDefaults.temperature,
        topP: Float = GenerationDefaults.topP,
        repetitionPenalty: Float = GenerationDefaults.repetitionPenalty,
        repetitionContextSize: Int = GenerationDefaults.repetitionContextSize,
        logger: Logger
    ) async throws -> String? {
        var messages: [Requests.Chat.Get.Message] = [Requests.Chat.Get.Message(
            role: ChatMessageRequestRole.user.rawValue,
            content: prompt
        )]

        if let systemPrompt {
            messages.append(Requests.Chat.Get.Message(
                role: ChatMessageRequestRole.system.rawValue,
                content: systemPrompt
            ))
        }

        let network = NetworkService(logger: logger, base: .mistral)

        logger.info(
            "Sending Standalone chat request to the API.")

        let generationParameters = ChatGenerationParameters(
            maxTokens: maxTokens ?? GenerationDefaults.maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            kvBits: nil,
            kvGroupSize: GenerationDefaults.kvGroupSize,
            quantizedKVStart: GenerationDefaults.quantizedKVStart
        )

        let response = try await network.request(
            Requests.Chat
                .Get(
                    model: "mistral-tiny",
                    messages: messages,
                    maxTokens: generationParameters.maxTokens,
                    temperature: generationParameters.temperature,
                    topP: generationParameters.topP
                )
        )

        return response.choices.first?.message.content ?? "Unknown"
    }
    
    /// Runs a standalone generation on a default loaded LLM.
    /// - Parameters:
    ///   - prompt: The prompt
    ///   - modelProvider: The modelProvider
    ///   - logger: The logger
    /// - Returns: The generation, first choice as a chat completion result
    static func runEmbedding(
        _ texts: [String],
        modelProvider: EmbeddingModelProvider,
        logger: Logger,
        priority: Bool = false
    ) async throws -> [EmbeddingData] {
        return try await modelProvider.run(texts, logger: logger, priority: priority).result
    }
    
    /// Runs a standalone generation using the mistral API.
    /// - Parameters:
    ///   - prompt: The prompt
    ///   - logger: The logger
    /// - Returns: The generation, first choice as a chat completion result
    static func runAPIEmbedding(
        _ texts: [String],
        logger: Logger
    ) async throws -> [EmbeddingData] {
        var allData: [EmbeddingData] = []

        let network = NetworkService(logger: logger, base: .mistral)
        let response = try await network.request(
            Requests.Embedding
                .Get(
                    input: texts,
                    model: "mistral-embed",
                    encodingFormat: "float"
                )
        )
        
        for data in response.data {
            allData
                .append(
                    .init(
                        embedding: .floats(data.embedding),
                        index: data.index
                    )
                )
        }
        
        return allData
    }
}
