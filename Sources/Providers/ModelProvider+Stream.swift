//
//  ModelProvider+Stream.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 3/21/26.
//

import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Internal stream delta (provider-neutral)

struct StreamDelta: Codable {
    let role: String?
    let content: String?
}

// MARK: - ModelProvider Streaming

extension ModelProvider {
    /// Streams a generation from the global LLM using SSE, yielding text deltas
    /// as they arrive. Delegates to `runStreamMistral` when the resolved model
    /// is Mistral-family; otherwise speaks Tinker's Anthropic-compatible
    /// Messages API directly.
    ///
    /// Anthropic events (`content_block_delta` → text, `message_stop` → end) are mapped
    /// into the internal `StreamDelta` contract so downstream handlers stay provider-agnostic.
    /// - Returns: An `AsyncThrowingStream` of `StreamDelta` tokens and the resolved model name.
    func runStream(
        _ prompt: UserInput.Prompt,
        generationParameters: ChatGenerationParameters,
        model: String? = nil,
        logger: Logger
    ) async throws -> AsyncThrowingStream<StreamDelta, Error> {
        var system: String?
        var messages: [[String: String]] = []
        switch prompt {
        case .messages(let generatedMessages):
            for message in generatedMessages {
                if let roleValue = message[MessageProcessingKeys.role] as? String,
                   let contentValue = message[MessageProcessingKeys.content] as? String,
                   contentValue.isEmpty == false {
                    if roleValue == ChatMessageRequestRole.system.rawValue {
                        system = [system, contentValue].compactMap { $0 }.joined(separator: "\n\n")
                    } else {
                        messages.append(["role": roleValue, "content": contentValue])
                    }
                }
            }
        default:
            break
        }

        let resolvedModel = ModelConfig.resolveChatModel(requested: model)
        logger.info("⚜️ Streaming \(messages.count) messages via \(resolvedModel)")

        if ModelConfig.isMistralModel(resolvedModel) {
            // Mistral chat-completions: system rides inline as a leading
            // message rather than a top-level field.
            var mistralMessages = messages
            if let system {
                mistralMessages.insert(["role": "system", "content": system], at: 0)
            }
            return try await runStreamMistral(
                messages: mistralMessages,
                generationParameters: generationParameters,
                model: resolvedModel,
                logger: logger
            )
        }

        var requestBody: [String: Any] = [
            "model": resolvedModel,
            "messages": messages,
            // Thinking floor: see ModelConfig.chatMaxTokens — truncated thinking
            // models return their reasoning as text.
            "max_tokens": ModelConfig.chatMaxTokens(
                requested: generationParameters.maxTokens, model: resolvedModel),
            "temperature": Double(generationParameters.temperature),
            "top_p": Double(generationParameters.topP),
            "stream": true
        ]
        if let system {
            requestBody["system"] = system
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        let base = NetworkService.BaseEndpoint.globalLLM
        var urlRequest = URLRequest(
            url: URL(string: "https://\(base.host)\(base.pathPrefix)/v1/messages")!
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(base.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = bodyData

        let decoder = JSONDecoder()

        // Parses one SSE `data:` payload; returns a delta to yield and whether the
        // message has finished.
        func handle(payload: String) -> (delta: StreamDelta?, done: Bool) {
            guard let data = payload.data(using: .utf8),
                  let event = try? decoder.decode(Requests.Messages.StreamEvent.self, from: data) else {
                return (nil, false)
            }
            switch event.type {
            case "message_start":
                return (StreamDelta(role: "assistant", content: nil), false)
            case "content_block_delta":
                if event.delta?.type == "text_delta", let text = event.delta?.text {
                    return (StreamDelta(role: nil, content: text), false)
                }
                return (nil, false)
            case "message_delta":
                if let stopReason = event.delta?.stopReason, stopReason != "end_turn" {
                    // max_tokens here with no text yielded means the model spent
                    // the whole budget thinking — surface it instead of silence.
                    logger.warning("Stream stopped early: stop_reason=\(stopReason)")
                }
                return (nil, false)
            case "message_stop":
                return (nil, true)
            case "error":
                logger.warning("Stream error event: \(payload)")
                return (nil, true)
            default:
                // ping / content_block_start / content_block_stop
                return (nil, false)
            }
        }

        return Self.sseStream(urlRequest: urlRequest, handle: handle)
    }

    /// Streams a generation from the Mistral chat-completions API (OpenAI-style
    /// SSE). Used by the realtime route's opening pass, which needs a fast
    /// non-thinking model: Tinker's thinking phase is unstreamed, so its TTFT
    /// equals the whole deliberation — the opposite of "instant".
    ///
    /// Messages are plain role/content pairs; Mistral accepts the `system`
    /// role inline, so no hoisting happens here.
    func runStreamMistral(
        messages: [[String: String]],
        generationParameters: ChatGenerationParameters,
        model: String,
        logger: Logger
    ) async throws -> AsyncThrowingStream<StreamDelta, Error> {
        logger.info("⚜️ Streaming \(messages.count) messages via \(model) (mistral)")

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": generationParameters.maxTokens,
            "temperature": Double(generationParameters.temperature),
            "top_p": Double(generationParameters.topP),
            "stream": true
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        let base = NetworkService.BaseEndpoint.mistral
        var urlRequest = URLRequest(
            url: URL(string: "https://\(base.host)/v1/chat/completions")!
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(base.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = bodyData

        let decoder = JSONDecoder()

        struct MistralStreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let role: String?
                    let content: String?
                }
                let delta: Delta?
                let finishReason: String?
                enum CodingKeys: String, CodingKey {
                    case delta
                    case finishReason = "finish_reason"
                }
            }
            let choices: [Choice]?
        }

        func handle(payload: String) -> (delta: StreamDelta?, done: Bool) {
            if payload == "[DONE]" { return (nil, true) }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(MistralStreamChunk.self, from: data),
                  let choice = chunk.choices?.first else {
                return (nil, false)
            }
            let delta = choice.delta.map { StreamDelta(role: $0.role, content: $0.content) }
            return (delta, choice.finishReason != nil)
        }

        return Self.sseStream(urlRequest: urlRequest, handle: handle)
    }

    /// Shared SSE driver: runs `urlRequest`, feeds each `data:` payload to
    /// `handle`, yields deltas until `handle` reports completion. Linux
    /// buffers the whole body (FoundationNetworking has no `URLSession.bytes`).
    private static func sseStream(
        urlRequest: URLRequest,
        handle: @escaping @Sendable (String) -> (delta: StreamDelta?, done: Bool)
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(FoundationNetworking)
                    // Linux: FoundationNetworking does not expose URLSession.bytes.
                    // Fall back to a single-shot request and parse the buffered SSE body.
                    let (data, _) = try await withCheckedThrowingContinuation {
                        (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
                            if let error { cont.resume(throwing: error); return }
                            cont.resume(returning: (data ?? Data(), response!))
                        }.resume()
                    }
                    if let text = String(data: data, encoding: .utf8) {
                        for line in text.components(separatedBy: "\n") {
                            guard line.hasPrefix("data: ") else { continue }
                            let (delta, done) = handle(String(line.dropFirst(6)))
                            if let delta { continuation.yield(delta) }
                            if done { break }
                        }
                    }
                    continuation.finish()
                    #else
                    let (asyncBytes, _) = try await URLSession.shared.bytes(for: urlRequest)
                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let (delta, done) = handle(String(line.dropFirst(6)))
                        if let delta { continuation.yield(delta) }
                        if done {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
