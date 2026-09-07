//
//  LocalInference.swift
//  Sewn
//
//  WHAT: On-device generation through Frigate MLX, inside Sewn. The `.local`
//        provider's whole implementation.
//  IN:   ModelProvider (never a route directly)
//  OUT:  text + tool calls, or a StreamDelta stream
//  PIN:  MLXLMCommon's UserInput/Chat/Message/JSONValue are SHADOWED by this
//        module's own vestigial declarations (Sources/API/MLXModels), so every
//        MLX type here is fully qualified. Requires mlx.metallib beside the
//        binary — see scripts/build-metallib.sh.
//

import Foundation
import Logging

/// What the on-device backend can answer right now.
enum LocalState: Sendable, Equatable {
    case cold
    case loading(Double)
    case ready(String)
    case failed(String)

    var name: String {
        switch self {
        case .cold: return "cold"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    var fraction: Double? {
        if case .loading(let value) = self { return value }
        return nil
    }

    var reason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

#if canImport(MLXLLM)

import MLXLLM
import MLXLMCommon

/// One resident model, one generation at a time. A second model id evicts the
/// first rather than holding two multi-gigabyte contexts on one GPU.
actor LocalInference {

    private let logger: Logger
    private var context: ModelContext?
    private var loadedModelID: String?
    private var state: LocalState = .cold
    /// One generation at a time: MLX's concurrent generate is not safe on a
    /// shared context, and two turns would interleave tokens.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(logger: Logger) {
        self.logger = logger
    }

    var isBuilt: Bool { true }

    func snapshot() -> LocalState { state }

    /// Load (downloading on first use) so the next request does not pay for it.
    func warm(modelID: String) async {
        do {
            _ = try await loadedContext(modelID: modelID)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    // MARK: - Generation

    func generate(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int
    ) async throws -> (text: String, toolCalls: [(name: String, arguments: String)]) {
        var text = ""
        var calls: [(name: String, arguments: String)] = []
        for try await event in stream(
            system: system, messages: messages, tools: tools,
            modelID: modelID, maxTokens: maxTokens)
        {
            switch event {
            case .text(let chunk): text += chunk
            case .toolCall(let name, let arguments): calls.append((name, arguments))
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    enum Event: Sendable {
        case text(String)
        case toolCall(name: String, arguments: String)
    }

    nonisolated func stream(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.round(
                        system: system, messages: messages, tools: tools,
                        modelID: modelID, maxTokens: maxTokens,
                        continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func round(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        let ctx = try await loadedContext(modelID: modelID)

        var chat: [MLXLMCommon.Chat.Message] = [
            .system(LocalMessageMapper.systemText(system, tools: tools))
        ]
        for turn in LocalMessageMapper.alternating(messages) {
            chat.append(turn.isUser ? .user(turn.text) : .assistant(turn.text))
        }

        await acquire()
        // RELEASED ON EVERY EXIT, cancellation included: a client that hangs up
        // mid-stream (SSE close, realtime turn.cancel) must not wedge the gate
        // for every later generation.
        defer { release() }

        let input = try await ctx.processor.prepare(
            input: MLXLMCommon.UserInput(
                chat: chat,
                tools: (tools?.isEmpty ?? true)
                    ? nil : tools?.map(LocalMessageMapper.toolSpec(from:))))
        let generation = try MLXLMCommon.generate(
            input: input,
            parameters: MLXLMCommon.GenerateParameters(maxTokens: maxTokens),
            context: ctx)

        var raw = ""
        for await item in generation {
            if Task.isCancelled { break }
            switch item {
            case .chunk(let text):
                raw += text
                continuation.yield(.text(text))
            case .toolCall(let call):
                let argumentsJSON: String
                if let data = try? JSONSerialization.data(
                    withJSONObject: call.function.arguments.mapValues { $0.anyValue }),
                    let json = String(data: data, encoding: .utf8) {
                    argumentsJSON = json
                } else {
                    argumentsJSON = "{}"
                }
                continuation.yield(.toolCall(name: call.function.name, arguments: argumentsJSON))
            case .info:
                break
            }
        }
        // Small Mistrals often narrate the call as text rather than emitting
        // the native wrapper. The skills route's own recovery is the parser.
        for recovered in skillsCompleteParseToolCalls(from: raw) {
            continuation.yield(.toolCall(name: recovered.name, arguments: recovered.arguments))
        }
    }

    // MARK: - Model residency

    private func loadedContext(modelID: String) async throws -> ModelContext {
        if let context, loadedModelID == modelID { return context }
        if loadedModelID != nil, loadedModelID != modelID {
            logger.info("[local] evicting \(loadedModelID ?? "") for \(modelID)")
            context = nil
            loadedModelID = nil
        }
        guard LocalGPU.report().isSatisfied else {
            state = .failed(LocalGPU.remedy())
            throw ProviderUnavailable.localFailed(LocalGPU.remedy())
        }
        state = .loading(0)
        logger.info("[local] loading \(modelID)")
        do {
            let ctx = try await MLXLMCommon.loadModel(
                configuration: MLXLMCommon.ModelConfiguration(id: modelID),
                progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { await self?.noteProgress(fraction) }
                })
            context = ctx
            loadedModelID = modelID
            state = .ready(modelID)
            logger.info("[local] ready \(modelID)")
            return ctx
        } catch {
            let reason = String(describing: error)
            state = .failed(reason)
            throw ProviderUnavailable.localFailed(reason)
        }
    }

    private func noteProgress(_ fraction: Double) {
        if case .loading = state { state = .loading(fraction) }
    }

    // MARK: - The one-at-a-time gate

    private func acquire() async {
        while busy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        busy = true
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

#else

/// The backend this build does not have. Same surface, honest refusal — a
/// Linux Sewn answers 503 rather than failing to compile.
actor LocalInference {

    init(logger: Logger) {}

    var isBuilt: Bool { false }

    func snapshot() -> LocalState { .failed("MLX is macOS-only in this build.") }

    func warm(modelID: String) async {}

    enum Event: Sendable {
        case text(String)
        case toolCall(name: String, arguments: String)
    }

    func generate(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int
    ) async throws -> (text: String, toolCalls: [(name: String, arguments: String)]) {
        throw ProviderUnavailable.localNotBuilt
    }

    nonisolated func stream(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderUnavailable.localNotBuilt) }
    }
}

#endif
