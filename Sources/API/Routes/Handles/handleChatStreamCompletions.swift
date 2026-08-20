//
//  handleChatStreamCompletions.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 3/21/26.
//

import Hummingbird
import HTTPTypes
import NIOCore
import Foundation
import Logging

func handleChatStreamCompletions(
    request: Request,
    context: SeerRequestContext,
    chatRequest: ChatCompletionRequest,
    seer: Seer,
    isVLM: Bool = false,
    modelProvider: ModelProvider
) async throws -> Response {
    let responseId = "api-chatcmpl-\(UUID().uuidString)"
    let created = Int(Date().timeIntervalSince1970)
    let logger = context.logger
    let handlerStartNs = DispatchTime.now().uptimeNanoseconds

    logger.info("Received API CHAT streaming completion request.")

    let seerRequest = try chatRequest.seer.from(context)
    let chatResult = try await _processUserMessages(
        chatRequest,
        seer,
        modelProvider: modelProvider,
        isVLM: isVLM,
        seerRequest: seerRequest
    )

    let userInput = chatResult.input

    if isVLM {
        logger.info(
            "VLM: Processing request with \(userInput.images.count) images and \(userInput.videos.count) videos"
        )
    }

    let sinatraTone = chatResult.tone
    let personality = chatResult.personality
    // Resolve the model before the token budget: thinking models get a floor
    // so truncation never swallows the answer (see ModelConfig.chatMaxTokens).
    let requestedModel = chatRequest.model ?? personality?.modelOverride
    let resolvedModel = ModelConfig.resolveChatModel(requested: requestedModel)
    let maxTokens = ModelConfig.chatMaxTokens(requested: chatRequest.maxTokens,
                                              model: resolvedModel)
    // Precedence: explicit request > personality (deliberate persona choice)
    // > adaptive tone > defaults.
    let temperature = chatRequest.temperature
        ?? personality?.temperature
        ?? sinatraTone?.temperature
        ?? GenerationDefaults.temperature
    let topP = chatRequest.topP
        ?? personality?.topP
        ?? sinatraTone?.topP
        ?? GenerationDefaults.topP
    let repetitionPenalty = sinatraTone?.repetitionPenalty
        ?? chatRequest.repetitionPenalty
        ?? GenerationDefaults.repetitionPenalty
    let repetitionContextSize = sinatraTone?.repetitionContextSize
        ?? chatRequest.repetitionContextSize
        ?? GenerationDefaults.repetitionContextSize
    let kvBits = chatRequest.kvBits
    let kvGroupSize = chatRequest.kvGroupSize ?? GenerationDefaults.kvGroupSize
    let quantizedKVStart = chatRequest.quantizedKVStart ?? GenerationDefaults.quantizedKVStart

    let generationParameters = ChatGenerationParameters(
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP,
        repetitionPenalty: repetitionPenalty,
        repetitionContextSize: repetitionContextSize,
        kvBits: kvBits,
        kvGroupSize: kvGroupSize,
        quantizedKVStart: quantizedKVStart
    )

    let references = chatResult.references
    let contribution = chatResult.contribution
    let partitions = chatResult.partitions
    let compactCitations = chatResult.compactCitations
    let sourceIndex = chatResult.sourceIndex
    let autoMemory = chatResult.autoMemory
    let sinatraTask = chatResult.sinatraTask

    let encoder = JSONEncoder()

    var headers = HTTPFields()
    headers[.contentType] = "text/event-stream"
    headers[.cacheControl] = "no-cache"
    headers[HTTPField.Name("X-Accel-Buffering")!] = "no"

    let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()

    let responseModelName = "api-\(resolvedModel)"

    Task {
        do {
            let prestreamNs = DispatchTime.now().uptimeNanoseconds - handlerStartNs
            logger.info("[timing] prestream \(prestreamNs / 1_000_000)ms")

            let modelStream = try await modelProvider.runStream(
                userInput.prompt,
                generationParameters: generationParameters,
                model: requestedModel,
                logger: logger
            )

            var isFirst = true
            var firstTokenNs: UInt64?
            var rawText = ""            // full model output, markers included
            var accumulatedText = ""    // user-visible text (markers stripped)
            var markerFilter = Gita.MarkerStreamFilter()

            func emit(content: String?, role: String?) {
                let chunk = ChatCompletionChunkResponse(
                    id: responseId,
                    created: created,
                    model: responseModelName,
                    choices: [
                        ChatCompletionChoiceDelta(
                            index: 0,
                            delta: ChatCompletionDelta(role: role, content: content),
                            finishReason: nil
                        )
                    ],
                    references: isFirst ? references : [],
                    contribution: nil,
                    autoMemory: autoMemory,
                    personality: isFirst ? personality?.id : nil
                )
                isFirst = false
                if let jsonData = try? encoder.encode(chunk),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    continuation.yield(ByteBuffer(string: "data: \(jsonString)\n\n"))
                }
            }

            for try await delta in modelStream {
                // Strip [[n]] citation markers before anything reaches the
                // client; the filter holds back partial markers split across
                // deltas so the streamed text always equals the final visible text.
                var visible = ""
                if let content = delta.content {
                    rawText += content
                    visible = markerFilter.feed(content)
                }
                accumulatedText += visible
                if !visible.isEmpty, firstTokenNs == nil {
                    let now = DispatchTime.now().uptimeNanoseconds
                    firstTokenNs = now
                    let ttftNs = now - handlerStartNs
                    SeerMetrics.chatTTFT.recordNanoseconds(Int64(ttftNs))
                    logger.info("[timing] ttft \(ttftNs / 1_000_000)ms")
                }
                // Emit when there is visible content, or for the very first
                // chunk (which announces the role and carries references).
                if !visible.isEmpty || isFirst {
                    emit(content: visible.isEmpty ? nil : visible,
                         role: isFirst ? "assistant" : nil)
                }
            }
            let tail = markerFilter.finish()
            if !tail.isEmpty {
                emit(content: tail, role: nil)
                accumulatedText += tail
            }

            if let firstTokenNs {
                let streamNs = DispatchTime.now().uptimeNanoseconds - firstTokenNs
                SeerMetrics.chatStreamDuration.recordNanoseconds(Int64(streamNs))
                logger.info("[timing] stream \(streamNs / 1_000_000)ms")
            }

            // Compute spans now that the full response text is available:
            // exact spans from citation markers + heuristic fallback, then emit
            // a final metadata chunk carrying the annotated contribution.
            if let baseContribution = contribution {
                let annotated = Gita.annotate(
                    responseText: rawText,
                    contribution: baseContribution,
                    partitions: partitions,
                    compactCitations: compactCitations,
                    sourceIndex: sourceIndex
                )
                let annotatedContribution = annotated.contribution
                let contributionChunk = ChatCompletionChunkResponse(
                    id: responseId,
                    created: created,
                    model: responseModelName,
                    choices: [],
                    references: [],
                    contribution: annotatedContribution,
                    autoMemory: autoMemory
                )
                if let jsonData = try? encoder.encode(contributionChunk),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    continuation.yield(ByteBuffer(string: "data: \(jsonString)\n\n"))
                }
            }

            continuation.yield(ByteBuffer(string: "data: [DONE]\n\n"))

            // ── Billing (post-stream, client already received [DONE]) ─────
            // All estimation logic lives in Gita.StreamBilling — adjust
            // the heuristic or strategy there without touching this handler.
            // Await the Sinatra task here so we can extract both the ledger
            // (for billing) and the documentStatsUpdates (for the registry).
            let sinatraPrepareResult = try? await sinatraTask?.value
            if let statsUpdates = sinatraPrepareResult?.documentStatsUpdates, !statsUpdates.isEmpty {
                seer.accumulatePerformance(statsUpdates)
            }
            // Store the resonance partition in the user's "Resonance" group when one
            // was detected — fire-and-forget via IndexQueue.
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
            if let baseContribution = contribution {
                let priced = await Gita.StreamBilling.price(
                    contribution: baseContribution,
                    prompt: userInput.prompt,
                    accumulatedText: accumulatedText,
                    sinatraLedger: sinatraPrepareResult?.ledger,
                    gita: seer.gita,
                    request: seerRequest
                )
                let totemIds = references.compactMap(\.totemId)
                seer.accumulateEarnings(from: priced, totemIds: totemIds)
            }
            // ─────────────────────────────────────────────────────────────

            continuation.finish()
            logger.info("API Streaming CHAT response completed (ID: \(responseId)).")
        } catch {
            continuation.finish(throwing: error)
            logger.error("API Streaming CHAT error (ID: \(responseId)): \(error)")
        }
    }

    return Response(status: .ok, headers: headers, body: .init(asyncSequence: stream))
}
