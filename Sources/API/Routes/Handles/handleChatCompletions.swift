import Foundation
//
//  APIChatCompletionsRoute.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 12/21/25.
//

import Hummingbird

func handleChatCompletions(
    request: Request,
    context: SeerRequestContext,
    chatRequest: ChatCompletionRequest,
    seer: Seer,
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

    // Extract SeerRequest once — used for log correlation and Gita pricing.
    let seerRequest = try chatRequest.seer.from(context)

    // Process user messages, chat history.
    let chatResult = try await _processUserMessages(
        chatRequest,
        seer,
        modelProvider: modelProvider,
        isVLM: isVLM,
        seerRequest: seerRequest
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
    let requestedModel = chatRequest.model ?? personality?.modelOverride
    let resolvedModel = ModelConfig.resolveChatModel(requested: requestedModel)
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
    let result = try await modelProvider.run(
        userInput.prompt,
        generationParameters: generationParameters,
        model: requestedModel,
        logger: context.logger
    )

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
        seer.accumulatePerformance(statsUpdates)
    }
    // Store the resonance partition in the user's "Resonance" group when one was
    // detected. This is fire-and-forget via the IndexQueue — the response is never
    // delayed by the write.
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
        seer.gita.priceContribution(
            $0,
            ledger: tokenLedger,
            strategy: .default,
            currentLoad: 1,
            request: seerRequest
        )
    }

    // Persist document-level earnings to the registry — fire-and-forget.
    // Runs through RegistryMutator so writes are serialized and debounced.
    if let pricedContribution {
        let totemIds = gitaResponseContext.references.compactMap(\.totemId)
        seer.accumulateEarnings(from: pricedContribution, totemIds: totemIds)
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

    seer.logger.info(
        "Usage",
        "\(result.usage.description)",
        service: .gita,
        request: seerRequest,
        flow: .chat
    )

    seer.logger.info(
        "Chat Complete",
        "API Non-streaming CHAT response generated (ID: \(responseId)).",
        service: .gita,
        request: seerRequest,
        flow: .chat
    )

    return chatResponse
}
