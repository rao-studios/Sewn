//
//  LocalInference.swift
//  Sewn
//
//  WHAT: On-device generation through SinatraHarness — the harness over Frigate MLX whose
//        injection layer adds a bias to the logits right before decoding, learned from
//        how well earlier answers followed their retrieved context (grounding). The
//        `.local` provider's whole implementation.
//  IN:   ModelProvider (never a route directly)
//  OUT:  text + tool calls (+ SinatraHarness diagnostics on chat turns), or a stream of them
//  PIN:  MLXLMCommon's UserInput/Chat/Message/JSONValue are SHADOWED by this
//        module's own vestigial declarations (Sources/API/MLXModels), and Sewn has its
//        own OwnerID, so every MLX and SinatraHarness type here is fully qualified.
//        Requires mlx.metallib beside the binary — see scripts/build-metallib.sh.
//        One resident model and one generation at a time live in the harness; its gate
//        also serialises SinatraHarness's context encoding, tracing and training.
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

/// Where SinatraHarness keeps its ledgers, weight models and traces under the data root.
/// The folder was `sinatra-mlx` before the package was renamed from SinatraMLX: an existing
/// one moves across once, so nothing it learned is stranded, and a new store is never
/// overwritten.
enum LocalStore {
    static let folder = "sinatra-harness"
    static let legacyFolder = "sinatra-mlx"

    static func directory(root: URL, fileManager: FileManager = .default) -> URL {
        let store = root.appendingPathComponent(folder, isDirectory: true)
        let legacy = root.appendingPathComponent(legacyFolder, isDirectory: true)
        if !fileManager.fileExists(atPath: store.path(percentEncoded: false)),
            fileManager.fileExists(atPath: legacy.path(percentEncoded: false))
        {
            try? fileManager.moveItem(at: legacy, to: store)
        }
        return store
    }
}

#if canImport(MLXLLM)

import MLXLLM
import MLXLMCommon
import FrigateBridge
import SinatraHarness

actor LocalInference {

    private let logger: Logger
    private let harness: SinatraHarness.Harness
    /// The Metal library is missing: reported instead of the harness state.
    private var gpuFailure: String?
    /// Off only under `swift test`, where the running binary is Xcode's test runner, not
    /// the bundle MLX actually loads its metallib beside.
    private let gpuPreflight: Bool

    /// SinatraHarness keeps its ledgers, weight models and traces under the data root.
    init(logger: Logger, storeDirectory: URL? = nil, gpuPreflight: Bool = true) {
        self.logger = logger
        self.gpuPreflight = gpuPreflight
        let store = storeDirectory ?? LocalStore.directory(root: FilePersistence.getDefaultURL())
        self.harness = SinatraHarness.Harness(
            storeDirectory: store, configuration: Self.sinatraConfiguration(),
            log: SinatraLogBridge(logger: logger))
    }

    /// Environment overrides: SEWN_SINATRA_MODE (off|lexical|dense),
    /// SEWN_SINATRA_TRACE (automatic|off|summary|full), SEWN_SINATRA_ALPHA.
    static func sinatraConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SinatraHarness.SinatraConfiguration {
        var configuration = SinatraHarness.SinatraConfiguration()
        if let mode = environment["SEWN_SINATRA_MODE"].flatMap(SinatraHarness.BiasMode.init(rawValue:)) {
            configuration.biasMode = mode
        }
        if let trace = environment["SEWN_SINATRA_TRACE"].flatMap(SinatraHarness.TraceLevel.init(rawValue:)) {
            configuration.traceLevel = trace
        }
        if let alpha = environment["SEWN_SINATRA_ALPHA"].flatMap(Float.init) {
            configuration.alpha = alpha
        }
        return configuration
    }

    var isBuilt: Bool { true }

    func snapshot() async -> LocalState {
        if let gpuFailure { return .failed(gpuFailure) }
        switch await harness.state {
        case .cold: return .cold
        case .loading(let fraction): return .loading(fraction)
        case .ready(let model): return .ready(model)
        case .failed(let reason): return .failed(reason)
        }
    }

    /// Load (downloading on first use) so the next request does not pay for it.
    func warm(modelID: String) async {
        do {
            try await ensureLoaded(modelID: modelID)
        } catch {
            logger.error("[local] warm \(modelID) failed: \(error)")
        }
    }

    private func ensureLoaded(modelID: String) async throws {
        guard !gpuPreflight || LocalGPU.report().isSatisfied else {
            gpuFailure = LocalGPU.remedy()
            throw ProviderUnavailable.localFailed(LocalGPU.remedy())
        }
        gpuFailure = nil
        do {
            try await harness.load(modelID: modelID)
        } catch {
            throw ProviderUnavailable.localFailed(String(describing: error))
        }
    }

    // MARK: - Generation

    enum Event: Sendable {
        case text(String)
        case toolCall(name: String, arguments: String)
        case sinatra(LocalSinatraDiagnostics)
    }

    /// Utility passes: no retrieval, no turn, nothing learned.
    func generate(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int
    ) async throws -> (text: String, toolCalls: [(name: String, arguments: String)]) {
        let result = try await generate(
            system: system, messages: messages, tools: tools, modelID: modelID,
            sampling: .utility(maxTokens: maxTokens), retrieved: [], turn: nil)
        return (result.text, result.toolCalls)
    }

    func generate(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        sampling: LocalSampling,
        retrieved: [Sewn.RetrievedPartition],
        turn: LocalTurnContext?
    ) async throws -> (text: String, toolCalls: [(name: String, arguments: String)], sinatra: LocalSinatraDiagnostics?) {
        var text = ""
        var calls: [(name: String, arguments: String)] = []
        var sinatra: LocalSinatraDiagnostics?
        for try await event in stream(
            system: system, messages: messages, tools: tools, modelID: modelID,
            sampling: sampling, retrieved: retrieved, turn: turn)
        {
            switch event {
            case .text(let chunk): text += chunk
            case .toolCall(let name, let arguments): calls.append((name, arguments))
            case .sinatra(let diagnostics): sinatra = diagnostics
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), calls, sinatra)
    }

    nonisolated func stream(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<Event, Error> {
        stream(
            system: system, messages: messages, tools: tools, modelID: modelID,
            sampling: .utility(maxTokens: maxTokens), retrieved: [], turn: nil)
    }

    /// A chat turn: with `turn`, SinatraHarness plans the injection from `retrieved`, decodes
    /// with it, records the turn for its reply to label, and ends with `.sinatra`.
    nonisolated func stream(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        sampling: LocalSampling,
        retrieved: [Sewn.RetrievedPartition],
        turn: LocalTurnContext?
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.round(
                        system: system, messages: messages, tools: tools, modelID: modelID,
                        sampling: sampling, retrieved: retrieved, turn: turn,
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
        sampling: LocalSampling,
        retrieved: [Sewn.RetrievedPartition],
        turn: LocalTurnContext?,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        try await ensureLoaded(modelID: modelID)

        // Strict alternation starting with the user, or the template rejects the turn.
        let toolSpecs = (tools?.isEmpty ?? true) ? nil : tools?.map(LocalMessageMapper.toolSpec(from:))
        let input = Self.userInput(system: system, messages: messages, tools: tools, toolSpecs: toolSpecs)
        // The same chat without its retrieved context: SinatraHarness scores the answer against
        // it after the decode to measure what the context did.
        let bareInput = turn?.bareSystem.map {
            Self.userInput(system: $0, messages: messages, tools: tools, toolSpecs: toolSpecs)
        }

        let options = turn?.options
        let request = SinatraHarness.GenerateRequest(
            input: input,
            parameters: Self.generateParameters(sampling, seed: options?.seed),
            turn: turn.map { Self.turnInput($0, retrieved: retrieved) },
            bareInput: bareInput,
            mode: options?.mode.flatMap(SinatraHarness.BiasMode.init(rawValue:)),
            trace: options?.trace.flatMap(SinatraHarness.TraceLevel.init(rawValue:)) ?? .automatic,
            record: options?.record ?? true)
        let handle = try await harness.generate(request)

        var raw = ""
        for await item in handle.stream {
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
        if turn != nil, !Task.isCancelled {
            let completion = await handle.completion.value
            if let diagnostics = Self.diagnostics(plan: handle.plan, completion: completion) {
                continuation.yield(.sinatra(diagnostics))
            }
        }
    }

    // MARK: - Mapping

    static func userInput(
        system: String?, messages: [Requests.Chat.Get.Message], tools: [Requests.Chat.Get.Tool]?,
        toolSpecs: [[String: any Sendable]]?
    ) -> MLXLMCommon.UserInput {
        let conversation = LocalMessageMapper.conversation(system: system, messages: messages, tools: tools)
        var chat: [MLXLMCommon.Chat.Message] = [.system(conversation.system)]
        for message in conversation.turns {
            chat.append(message.isUser ? .user(message.text) : .assistant(message.text))
        }
        return MLXLMCommon.UserInput(chat: chat, tools: toolSpecs)
    }

    /// The handler's sampling, now honoured on-device (it used to pass only maxTokens).
    static func generateParameters(_ sampling: LocalSampling, seed: UInt64? = nil) -> MLXLMCommon.GenerateParameters {
        MLXLMCommon.GenerateParameters(
            maxTokens: sampling.maxTokens,
            kvBits: sampling.kvBits,
            kvGroupSize: sampling.kvGroupSize,
            quantizedKVStart: sampling.quantizedKVStart,
            temperature: sampling.temperature,
            topP: sampling.topP,
            repetitionPenalty: sampling.repetitionPenalty == 1.0 ? nil : sampling.repetitionPenalty,
            repetitionContextSize: sampling.repetitionContextSize,
            seed: seed ?? sampling.seed)
    }

    static func turnInput(_ turn: LocalTurnContext, retrieved: [Sewn.RetrievedPartition]) -> SinatraHarness.TurnInput {
        SinatraHarness.TurnInput(
            owner: SinatraHarness.OwnerID(turn.owner),
            retrieved: retrieved.map {
                SinatraHarness.Partition(
                    id: $0.id, documentId: $0.documentId, text: $0.text, score: $0.score,
                    createdAt: $0.createdAt, modifiedAt: $0.modifiedAt)
            },
            conversationId: turn.conversationId,
            now: Date())
    }

    static func diagnostics(plan: SinatraHarness.InjectionPlan?, completion: SinatraHarness.TurnCompletion) -> LocalSinatraDiagnostics? {
        guard let plan else { return nil }
        let d = plan.diagnostics
        let summary = completion.summary
        let trace = completion.trace.map { t in
            LocalSinatraDiagnostics.TraceBrief(
                traceId: t.traceId.uuidString.lowercased(), level: t.level.rawValue, seed: t.seed,
                steps: t.summary.steps, meanEntropyPre: t.summary.meanEntropyPre,
                meanEntropyPost: t.summary.meanEntropyPost, meanEntropyShift: t.summary.meanEntropyShift,
                totalKl: t.summary.totalKL, totalGain: t.summary.totalGain,
                meanMassIntoMask: t.summary.meanMassIntoMask, divergenceRate: t.summary.divergenceRate,
                firstDivergenceStep: t.summary.firstDivergenceStep,
                flippedArgmaxSteps: t.summary.flippedArgmaxSteps,
                sampledInMaskShare: t.summary.sampledInMaskShare)
        }
        return LocalSinatraDiagnostics(
            turnId: plan.turnId.uuidString.lowercased(), mode: plan.mode.rawValue, coldStart: d.coldStart,
            partitions: d.partitions.count, weightedPartitions: d.weightedPartitions,
            biasTokens: d.biasNonZero, biasMaxAbs: d.biasMaxAbs, gate: d.gate,
            observations: summary?.observations ?? d.observedTurns,
            labelled: summary?.measuredTurns ?? d.measuredTurns,
            reliability: summary?.reliability ?? d.gate,
            trainedAt: SinatraDates.iso(summary?.trainedAt),
            trainingScheduled: completion.trainingScheduled,
            encodeMs: d.encodeMillis, trace: trace,
            grounding: completion.grounding.map(Self.groundingBrief))
    }

    static func groundingBrief(_ m: SinatraHarness.GroundingMeasurement) -> LocalSinatraDiagnostics.GroundingBrief {
        let s = m.summary
        return LocalSinatraDiagnostics.GroundingBrief(
            measured: m.measured, skippedReason: m.skippedReason, grounding: s.grounding, drift: s.drift,
            driftShare: s.driftShare, contextDependence: s.contextDependence, meanContextKl: s.meanContextKL,
            hallucinationRisk: s.hallucinationRisk, parrotShare: s.parrotShare, contentTokens: s.contentTokens,
            prefillMs: m.prefillMillis, scoreMs: m.scoreMillis,
            attribution: m.attribution.map {
                .init(partitionId: $0.partitionId, documentId: $0.documentId, nats: $0.nats,
                      uptake: $0.uptake, coverage: $0.coverage, parrot: $0.parrot)
            })
    }

    // MARK: - SinatraHarness status and reads

    func sinatraStatus(owner: String) async -> SinatraStatusInfo? {
        guard let summary = await harness.summary(owner: SinatraHarness.OwnerID(owner.lowercased())) else { return nil }
        return SinatraStatusInfo(
            observations: summary.observations, labelled: summary.measuredTurns,
            trainedAt: SinatraDates.iso(summary.trainedAt), reliability: summary.reliability,
            lastBiasMagnitude: summary.lastBiasMagnitude ?? 0, store: summary.store,
            turnsMeasured: summary.measuredTurns, groundingMean: summary.meanGrounding,
            driftMean: summary.meanDrift, hallucinationRiskMean: summary.meanHallucinationRisk)
    }

    /// The stored trace JSON for one of `owner`'s turns, or nil.
    func traceJSON(owner: String, turnId: UUID) async -> Data? {
        guard let trace = await harness.trace(owner: SinatraHarness.OwnerID(owner.lowercased()), turnId: turnId) else { return nil }
        return try? Self.encoder.encode(trace)
    }

    /// Grounding over the owner's band: does steering reduce drift, which documents are cited.
    func analysisJSON(owner: String) async -> Data? {
        guard let report = await harness.groundingReport(owner: SinatraHarness.OwnerID(owner.lowercased())) else { return nil }
        return try? Self.encoder.encode(report)
    }

    func forgetOwner(_ owner: String) async {
        try? await harness.forget(owner: SinatraHarness.OwnerID(owner.lowercased()))
    }

    func flush() async {
        await harness.flush()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()
}

/// SinatraHarness's log sink over swift-log.
struct SinatraLogBridge: SinatraHarness.SinatraLog {
    let logger: Logger

    func log(_ level: SinatraHarness.SinatraLogLevel, _ message: @autoclosure () -> String) {
        let text = "[sinatra-harness] \(message())"
        switch level {
        case .trace: logger.trace("\(text)")
        case .debug: logger.debug("\(text)")
        case .info: logger.info("\(text)")
        case .warning: logger.warning("\(text)")
        case .error: logger.error("\(text)")
        }
    }
}

#else

/// The backend this build does not have. Same surface, honest refusal — a
/// Linux Sewn answers 503 rather than failing to compile.
actor LocalInference {

    init(logger: Logger, storeDirectory: URL? = nil, gpuPreflight: Bool = true) {}

    var isBuilt: Bool { false }

    func snapshot() -> LocalState { .failed("MLX is macOS-only in this build.") }

    func warm(modelID: String) async {}

    enum Event: Sendable {
        case text(String)
        case toolCall(name: String, arguments: String)
        case sinatra(LocalSinatraDiagnostics)
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

    func generate(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        sampling: LocalSampling,
        retrieved: [Sewn.RetrievedPartition],
        turn: LocalTurnContext?
    ) async throws -> (text: String, toolCalls: [(name: String, arguments: String)], sinatra: LocalSinatraDiagnostics?) {
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

    nonisolated func stream(
        system: String?,
        messages: [Requests.Chat.Get.Message],
        tools: [Requests.Chat.Get.Tool]?,
        modelID: String,
        sampling: LocalSampling,
        retrieved: [Sewn.RetrievedPartition],
        turn: LocalTurnContext?
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderUnavailable.localNotBuilt) }
    }

    func sinatraStatus(owner: String) async -> SinatraStatusInfo? { nil }
    func traceJSON(owner: String, turnId: UUID) async -> Data? { nil }
    func analysisJSON(owner: String) async -> Data? { nil }
    func forgetOwner(_ owner: String) async {}
    func flush() async {}
}

#endif
