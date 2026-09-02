//
//  Realtime.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 7/22/26.
//
//  GET /v1/realtime/chat — WebSocket upgrade. One turn per connection:
//  the client sends a single `turn.start` frame (embedding the exact
//  ChatCompletionRequest JSON the SSE route accepts), the server streams
//  interleaved text tokens and TTS PCM, then a metadata chunk (contribution,
//  auto_memory) and `turn.end`. Client close (or a `cancel` frame) at any
//  point cancels all in-flight work — that IS the barge-in path.
//

import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore

// MARK: - Registration

func registerRealtimeRoute(
    _ router: Router<BasicWebSocketRequestContext>,
    _ seer: Seer,
    modelProvider: ModelProvider
) {
    router.ws(
        "/v1/realtime/chat",
        shouldUpgrade: { request, _ in
            // Same bearer scheme as AuthMiddleware, validated before the
            // upgrade completes. The result is cached by token, so the
            // handler's second validate() is a dictionary hit.
            guard let token = bearerToken(from: request) else {
                throw HTTPError(.unauthorized, message: "Missing bearer token")
            }
            _ = try await TokenValidator.validate(token)
            return .upgrade([:])
        },
        onUpgrade: { inbound, outbound, context in
            try await handleRealtimeTurn(
                inbound: inbound,
                outbound: outbound,
                context: context,
                seer: seer,
                modelProvider: modelProvider
            )
        }
    )
}

/// The opening-pass system prompt. This pass runs on a fast Mistral model
/// from conversation history alone (retrieval hasn't landed yet) and is the
/// FIRST thing spoken. Client instructions are dropped here. It must not
/// disclaim the client's parallel Skill lane — and it must not claim that
/// lane already ran. Extracted for unit testing.
func realtimeOpeningSystemPrompt(
    personality: Personality? = nil,
    persona inline: ChatPersona? = nil
) -> String {
    let persona = resolveChatPersona(inline: inline, stored: personality)
    return """
    Your name is \(persona.name).

    \(persona.voice)

    You act through your tools — if the user asks you to do something (edit code, write, change \
    a file, run something), name the heading in one beat and keep talking; never claim you are \
    doing it in the present ("opening that", "I'm adding that now"), never a result you have \
    not been given, and never explain how they would do it themselves.

    Give a one-to-two-sentence direct opening to your reply, from the conversation alone. Begin answering \
    substantively with what you know. Never say you are looking anything up, don't state specifics from the \
    user's notes or history you haven't confirmed yet, never enumerate sources, no filler openers ("Great \
    question", "Sure"). Plain spoken prose — no markdown, no lists. Your reply will be continued.
    """
}

private func bearerToken(from request: Request) -> String? {
    guard let auth = request.headers[.authorization], auth.hasPrefix("Bearer ") else { return nil }
    return String(auth.dropFirst("Bearer ".count))
}

// MARK: - Turn handling

private struct RealtimeClientClosed: Error {}

/// The inbound WebSocket stream iterates exactly once — the turn.start read
/// and the cancel watcher must share one iterator, sequentially. (A second
/// `messages(maxSize:)` iterator ends immediately and reads as client-close.)
private final class InboundReader: @unchecked Sendable {
    private var iterator: WebSocketInboundMessageStream.AsyncIterator

    init(_ stream: WebSocketInboundMessageStream) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> WebSocketMessage? {
        try await iterator.next()
    }
}

private func handleRealtimeTurn(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    context: WebSocketRouterContext<BasicWebSocketRequestContext>,
    seer: Seer,
    modelProvider: ModelProvider
) async throws {
    let logger = context.logger
    let maxFrameSize = 1 << 20

    let send: @Sendable (RealtimeOutbound) async throws -> Void = { frame in
        switch frame.payload {
        case .text(let text):     try await outbound.write(.text(text))
        case .binary(let data):   try await outbound.write(.binary(ByteBuffer(bytes: data)))
        }
    }

    // ── turn.start ───────────────────────────────────────────────────────────
    let reader = InboundReader(inbound.messages(maxSize: maxFrameSize))
    guard let first = try await reader.next(), case .text(let startText) = first else {
        try? await send(.error(stage: "request", message: "Expected a turn.start text frame"))
        return
    }
    let turnStart: RealtimeTurnStart
    do {
        turnStart = try JSONDecoder().decode(RealtimeTurnStart.self, from: Data(startText.utf8))
        guard turnStart.type == "turn.start" else {
            throw HTTPError(.badRequest, message: "First frame must be turn.start")
        }
    } catch {
        try? await send(.error(stage: "request", message: "Invalid turn.start: \(error)"))
        return
    }

    // Re-validate (cache hit) to bind the turn to the authed owner exactly the
    // way `SeerRequest.from(context)` does on the HTTP routes.
    guard let token = bearerToken(from: context.request) else {
        try? await send(.error(stage: "request", message: "Missing bearer token"))
        return
    }
    let user: TokenValidator.ValidatedUser
    do {
        user = try await TokenValidator.validate(token)
    } catch {
        try? await send(.error(stage: "request", message: "Invalid or expired access token"))
        return
    }

    let chatRequest = turnStart.request
    let requestID = UUID().uuidString
    let seerRequest = SeerRequest(
        ownerId: user.userId.lowercased(),
        group: chatRequest.seer.group,
        groups: chatRequest.seer.groups,
        entities: chatRequest.seer.entities,
        tags: chatRequest.seer.tags,
        aggregate: chatRequest.seer.aggregate,
        scope: chatRequest.seer.scope,
        totemIds: chatRequest.seer.totemIds,
        personalTotemId: chatRequest.seer.personalTotemId,
        requestID: requestID
    )

    SeerMetrics.realtimeTurns.increment()
    logger.info("[realtime] turn start — owner \(seerRequest.ownerId), request \(requestID)")

    // ── Engine wiring ─────────────────────────────────────────────────────────
    let personality = PersonalityStore.personality(id: chatRequest.personality)
    let openingSystemPrompt = realtimeOpeningSystemPrompt(
        personality: personality, persona: chatRequest.persona)

    let historyMessages: [[String: String]] = chatRequest.messages.compactMap { message in
        guard let content = message.content.asString, !content.isEmpty else { return nil }
        return ["role": message.role.rawValue, "content": content]
    }

    let requestedModel = chatRequest.model ?? personality?.modelOverride
    let resolvedModel = ModelConfig.resolveChatModel(requested: requestedModel)
    // Same precedence as the SSE handler, minus Sinatra tone — tone rides the
    // retrieval result, which the grounded closure predates. v1 accepts that.
    let groundedParameters = ChatGenerationParameters(
        maxTokens: ModelConfig.chatMaxTokens(requested: chatRequest.maxTokens, model: resolvedModel),
        temperature: chatRequest.temperature ?? personality?.temperature ?? GenerationDefaults.temperature,
        topP: chatRequest.topP ?? personality?.topP ?? GenerationDefaults.topP,
        repetitionPenalty: chatRequest.repetitionPenalty ?? GenerationDefaults.repetitionPenalty,
        repetitionContextSize: chatRequest.repetitionContextSize ?? GenerationDefaults.repetitionContextSize,
        kvBits: chatRequest.kvBits,
        kvGroupSize: chatRequest.kvGroupSize ?? GenerationDefaults.kvGroupSize,
        quantizedKVStart: chatRequest.quantizedKVStart ?? GenerationDefaults.quantizedKVStart
    )
    let openingParameters = ChatGenerationParameters(
        maxTokens: ModelConfig.openingMaxTokens,
        temperature: 0.3,
        topP: GenerationDefaults.topP,
        repetitionPenalty: GenerationDefaults.repetitionPenalty,
        repetitionContextSize: GenerationDefaults.repetitionContextSize,
        kvBits: nil,
        kvGroupSize: GenerationDefaults.kvGroupSize,
        quantizedKVStart: GenerationDefaults.quantizedKVStart
    )

    let ttsVoice = turnStart.tts?.voiceId ?? "fr_marie_neutral"
    let ttsModel = turnStart.tts?.model ?? MistralTTS.defaultModel

    let engine = RealtimeTurnEngine(
        deps: .init(
            opening: { messages in
                try await modelProvider.runStreamMistral(
                    messages: messages,
                    generationParameters: openingParameters,
                    model: ModelConfig.openingModel,
                    logger: logger
                )
            },
            retrieval: {
                try await seer.handleChat(
                    request: chatRequest,
                    modelProvider: modelProvider,
                    seerRequest: seerRequest,
                    queryExpansion: chatRequest.resonate ?? false
                )
            },
            grounded: { prompt in
                try await modelProvider.runStream(
                    prompt,
                    generationParameters: groundedParameters,
                    model: requestedModel,
                    logger: logger
                )
            },
            tts: { sentence in
                #if canImport(FoundationNetworking)
                // Linux: no streaming URLSession — one buffered delta per sentence.
                let pcm = try await MistralTTS.buffered(
                    text: sentence, voiceID: ttsVoice, model: ttsModel, logger: logger
                )
                return AsyncThrowingStream { continuation in
                    continuation.yield(pcm)
                    continuation.finish()
                }
                #else
                return try await MistralTTS.stream(
                    text: sentence, voiceID: ttsVoice, model: ttsModel, logger: logger
                )
                #endif
            }
        ),
        openingSystemPrompt: openingSystemPrompt,
        historyMessages: historyMessages,
        logger: logger
    )

    // ── Run: engine vs. client-cancel watcher ─────────────────────────────────
    var summary: RealtimeTurnEngine.Summary?
    let summaryBox = LockedValue<RealtimeTurnEngine.Summary?>(nil)
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let result = try await engine.run(send: send)
                summaryBox.withLock { $0 = result }
            }
            group.addTask {
                // Watch for a `cancel` frame or the client closing the socket,
                // continuing on the SAME iterator that read turn.start.
                while let message = try await reader.next() {
                    if case .text(let text) = message,
                       let probe = try? JSONDecoder().decode(RealtimeInboundProbe.self, from: Data(text.utf8)),
                       probe.type == "cancel" {
                        break
                    }
                }
                throw RealtimeClientClosed()
            }
            // First finisher wins: engine completion cancels the watcher;
            // client close/cancel kills the engine.
            do {
                _ = try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
        summary = summaryBox.withLock { $0 }
    } catch is RealtimeClientClosed {
        logger.info("[realtime] client closed/cancelled — turn aborted")
        return
    } catch is CancellationError {
        return
    } catch {
        logger.error("[realtime] turn failed: \(error)")
        try? await send(.error(stage: "opening", message: "\(error)"))
        return
    }

    guard let summary else { return }
    if summary.ttsFailed { SeerMetrics.realtimeTTSFailures.increment() }
    if let ms = summary.firstTokenMs { SeerMetrics.realtimeFirstToken.recordMilliseconds(ms) }
    if let ms = summary.firstAudioMs { SeerMetrics.realtimeFirstAudio.recordMilliseconds(ms) }
    if let ms = summary.retrievalWaitMs { SeerMetrics.realtimeRetrievalWait.recordMilliseconds(ms) }

    // ── Metadata chunk (SSE trailing-chunk shape, reused verbatim) ────────────
    let chatResult = summary.chatResult
    let responseId = "api-rtchat-\(UUID().uuidString)"
    let responseModelName = "api-\(resolvedModel)"
    if let baseContribution = chatResult?.contribution {
        let annotated = Gita.annotate(
            responseText: summary.openingText + summary.groundedRaw,
            contribution: baseContribution,
            partitions: chatResult?.partitions ?? [],
            compactCitations: chatResult?.compactCitations ?? [],
            sourceIndex: chatResult?.sourceIndex ?? [:]
        )
        let contributionChunk = ChatCompletionChunkResponse(
            id: responseId,
            model: responseModelName,
            choices: [],
            references: chatResult?.references ?? [],
            contribution: annotated.contribution,
            autoMemory: chatResult?.autoMemory ?? false
        )
        if let chunkJSON = try? JSONEncoder().encode(contributionChunk) {
            try await send(.metadata(chunkJSON: chunkJSON))
        }
    } else if chatResult?.autoMemory == true {
        let memoryChunk = ChatCompletionChunkResponse(
            id: responseId,
            model: responseModelName,
            choices: [],
            references: chatResult?.references ?? [],
            autoMemory: true
        )
        if let chunkJSON = try? JSONEncoder().encode(memoryChunk) {
            try await send(.metadata(chunkJSON: chunkJSON))
        }
    }

    try await send(.turnEnd)
    logger.info("[realtime] turn complete (ID: \(responseId))")

    // ── Billing (post-stream; mirrors handleChatStreamCompletions) ───────────
    if let chatResult {
        let sinatraPrepareResult = try? await chatResult.sinatraTask?.value
        if let statsUpdates = sinatraPrepareResult?.documentStatsUpdates, !statsUpdates.isEmpty {
            seer.accumulatePerformance(statsUpdates)
        }
        if let resonance = sinatraPrepareResult?.resonancePartition {
            let resonanceGroup = Seer.Group(
                id: "resonance-\(seerRequest.ownerId)",
                label: Sinatra.resonanceGroupLabel,
                ownerId: seerRequest.ownerId,
                documents: []
            )
            let resonanceRequest = SeerRequest(
                ownerId: seerRequest.ownerId,
                group: resonanceGroup,
                aggregate: nil,
                scope: nil,
                totemIds: seerRequest.personalTotemId.map { [$0] },
                requestID: nil
            )
            let item = Seer.BatchPutItem(
                id: resonance.documentId,
                texts: [resonance.text],
                tags: ["resonance"],
                tagsEmbedding: nil,
                mediaType: .text,
                update: nil,
                name: nil,
                metadata: nil
            )
            await seer.enqueuePut([item], request: resonanceRequest)
        }
        if let baseContribution = chatResult.contribution {
            let priced = await Gita.StreamBilling.price(
                contribution: baseContribution,
                prompt: chatResult.input.prompt,
                accumulatedText: summary.accumulatedText,
                sinatraLedger: sinatraPrepareResult?.ledger,
                gita: seer.gita,
                request: seerRequest
            )
            let totemIds = (chatResult.references).compactMap(\.totemId)
            seer.accumulateEarnings(from: priced, totemIds: totemIds)
        }
    }
}
