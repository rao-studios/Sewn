import Foundation
//
//  APIChatCompletionsRoute.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/21/25.
//

import Hummingbird

func handleChatCompletions(
    request: Request,
    context: SewnRequestContext,
    chatRequest: ChatCompletionRequest,
    sewn: Sewn,
    isVLM: Bool = false,
    modelProvider: ModelProvider
) async throws -> ChatCompletionResponse {
    // The route already consumed the body to branch on `stream` — the decoded
    // request is passed in; decoding here again would trap (body iterates once).
    let responseId = "api-chatcmpl-\(UUID().uuidString)"
    let created = Int(Date().timeIntervalSince1970)
    let logger = context.logger

    logger.info(
        "Received API CHAT completion request."
    )

    // Extract SewnRequest once — used for log correlation and Gita pricing.
    let sewnRequest = try chatRequest.sewn.from(context)

    // Process user messages, chat history.
    let chatResult = try await _processUserMessages(
        chatRequest,
        sewn,
        modelProvider: modelProvider,
        isVLM: isVLM,
        sewnRequest: sewnRequest
    )

    let userInput = chatResult.input

    // Continue sanitizing based on chat request type
    // Prepare for generation thereafter.
    if isVLM {
        logger.info(
            "VLM: Processing request with \(userInput.images.count) images and \(userInput.videos.count) videos"
        )
    }

    _ = chatRequest.stream ?? GenerationDefaults.stream
    _ = chatRequest.stop ?? GenerationDefaults.stopSequences

    // Generation-parameter precedence: explicit request > personality
    // (deliberate persona choice) > adaptive Sinatra tone > defaults.
    let sinatraTone = chatResult.tone
    let personality = chatResult.personality
    // Resolve the model before the token budget: thinking models get a floor
    // so truncation never swallows the answer (see ModelConfig.chatMaxTokens).
    let provider = chatRequest.provider ?? .serverDefault
    let requestedModel = chatRequest.model ?? personality?.modelOverride
    let resolvedModel = ModelConfig.resolveChatModel(
        requested: requestedModel, provider: provider)
    let maxTokens = ModelConfig.chatMaxTokens(requested: chatRequest.maxTokens,
                                              model: resolvedModel)
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

    let gitaResponseContext = GitaResponseContext(
        references: chatResult.references,
        contribution: chatResult.contribution
    )

    // Run primary LLM generation. Personality model override applies when the
    // request didn't pin a model.
    let result: (choices: [ChatCompletionChoice], usage: Requests.Chat.Get.Usage)
    do {
        result = try await modelProvider.run(
            userInput.prompt,
            generationParameters: generationParameters,
            model: requestedModel,
            provider: provider,
            logger: context.logger
        )
    } catch let error as ProviderUnavailable {
        logger.error("Chat provider unavailable: \(error)")
        throw HTTPError(.serviceUnavailable, message: error.description)
    }

    // Track token usage for the primary generation.
    var tokenLedger = Gita.TokenLedger()
    tokenLedger.record(
        model: resolvedModel,
        promptTokens: result.usage.promptTokens,
        completionTokens: result.usage.completionTokens
    )

    // Await Sinatra's concurrent task. The task started alongside the primary
    // generation, so it is typically already complete by the time we reach here
    // — zero latency added in the happy path.
    // Errors (e.g. LLM failure inside prepare) are swallowed: billing continues
    // with only the primary-generation cost rather than failing the response.
    let sinatraPrepareResult = try? await chatResult.sinatraTask?.value
    if let sinatraLedger = sinatraPrepareResult?.ledger {
        tokenLedger.merge(sinatraLedger)
    }
    if let statsUpdates = sinatraPrepareResult?.documentStatsUpdates, !statsUpdates.isEmpty {
        sewn.accumulatePerformance(statsUpdates)
    }
    // Store the resonance partition in the user's "Resonance" group when one was
    // detected. This is fire-and-forget via the IndexQueue — the response is never
    // delayed by the write.
    if let resonance = sinatraPrepareResult?.resonancePartition {
        let resonanceGroup = Sewn.Group(
            id: "resonance-\(sewnRequest.ownerId)",
            label: Sinatra.resonanceGroupLabel,
            ownerId: sewnRequest.ownerId,
            documents: []
        )
        let resonanceRequest = SewnRequest(
            ownerId: sewnRequest.ownerId,
            group: resonanceGroup,
            aggregate: nil,
            scope: nil,
            threadIds: sewnRequest.personalThreadId.map { [$0] },
            requestID: nil,
            callerApp: sewnRequest.callerApp
        )
        let item = Sewn.BatchPutItem(
            id: resonance.documentId,
            texts: [resonance.text],
            tags: ["resonance"],
            tagsEmbedding: nil,
            mediaType: .text,
            update: nil,
            name: nil,
            metadata: nil
        )
        await sewn.enqueuePut([item], request: resonanceRequest)
    }

    // Annotate each owner with response-text highlight spans now that we have
    // the completed generation: exact spans from [[n]] citation markers (which
    // are stripped from the visible text), heuristic n-gram spans for the rest.
    let rawResponseText = result.choices.first?.message.content ?? ""
    var visibleText = rawResponseText
    let annotatedContribution: Gita.Contribution? = chatResult.contribution.map {
        let annotated = Gita.annotate(
            responseText: rawResponseText,
            contribution: $0,
            partitions: chatResult.partitions,
            compactCitations: chatResult.compactCitations,
            sourceIndex: chatResult.sourceIndex
        )
        visibleText = annotated.visibleText
        return annotated.contribution
    }
    // Markers must never reach the client even when no contribution exists.
    if chatResult.contribution == nil {
        visibleText = Gita.parseMarkers(rawResponseText, sourceIndex: chatResult.sourceIndex).visibleText
    }
    let sanitizedChoices: [ChatCompletionChoice] = result.choices.enumerated().map { index, choice in
        guard index == 0 else { return choice }
        return ChatCompletionChoice(
            index: choice.index,
            message: .init(role: choice.message.role, content: visibleText),
            finishReason: choice.finishReason
        )
    }

    // Price the contribution: compute per-owner earnings, service charge, and
    // total cost in credits. Returns the annotated contribution unchanged when
    // no partitions were retrieved (ledger empty or no owners).
    // Logging (Token Ledger, Cost Breakdown, Owner Payouts) is emitted inside
    // priceContribution under service: .gita, flow: .chat.
    let pricedContribution: Gita.Contribution? = annotatedContribution.map {
        sewn.gita.priceContribution(
            $0,
            ledger: tokenLedger,
            strategy: .default,
            currentLoad: 1,
            request: sewnRequest
        )
    }

    // Persist document-level earnings to the registry — fire-and-forget.
    // Runs through RegistryMutator so writes are serialized and debounced.
    if let pricedContribution {
        let threadIds = gitaResponseContext.references.compactMap(\.threadId)
        sewn.accumulateEarnings(from: pricedContribution, threadIds: threadIds)
    }

    let chatResponse = ChatCompletionResponse(
        id: responseId,
        created: created,
        model: "api-\(resolvedModel)",
        choices: sanitizedChoices,
        usage: .init(
            promptTokens: result.usage.promptTokens,
            completionTokens: result.usage.completionTokens,
            totalTokens: result.usage.totalTokens
        ),
        references: gitaResponseContext.references,
        contribution: pricedContribution,
        autoMemory: chatResult.autoMemory,
        tone: sinatraTone,
        personality: personality?.id
    )

    sewn.logger.info(
        "Usage",
        "\(result.usage.description)",
        service: .gita,
        request: sewnRequest,
        flow: .chat
    )

    sewn.logger.info(
        "Chat Complete",
        "API Non-streaming CHAT response generated (ID: \(responseId)).",
        service: .gita,
        request: sewnRequest,
        flow: .chat
    )

    return chatResponse
}
