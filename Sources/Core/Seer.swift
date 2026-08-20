//
//  Seer.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/28/25.
//

/*
 "What all of us have to do is to make sure we are using AI in a way that is for the benefit of humanity, not to the detriment of humanity."
 - Tim Cook
 */

import Conduit
import Foundation
import Logging

actor Seer {
    internal let logger: SeerLogger
    internal let baseLogger: Logger
    internal let sinatra: Sinatra
    internal let gita: Gita
    internal let registryMutator: RegistryMutator
    let documentCache: DocumentCache

    /// Persistent node identity for this Seer instance.
    let nodeId: UUID

    /// Type-erased TotemQueryClient (cast to TotemQueryClient where needed).
    /// Stored as Sendable to keep the actor's stored properties isolation-clean.
    nonisolated(unsafe) var _totemQueryClient: (any Sendable)?

    // MARK: - Write queue (serialises all index mutations through a single FIFO drain)
    //
    // All insertions and deletions are routed through this queue so they never overlap.
    // The actor's isolation prevents concurrent access to `pending` and `isProcessing`.
    // When drain() is suspended awaiting a mutator, new enqueue() calls only append to
    // `pending[]` — they do NOT execute because `isProcessing` blocks a second drain.
    // This preserves the ordering guarantee: no removeBatch can interleave mid-putBatch.

    private enum WriteJob {
        case put([Seer.BatchPutItem], SeerRequest)
        case removeBatch([(documentId: String, ownerId: String)])
        case removeAll(ownerId: String, request: SeerRequest, CheckedContinuation<Int, Never>)
    }
    private var pending: [WriteJob] = []
    private var isProcessing = false

    init() {
        var baseLogger = Logger(label: "seer-logger")
        baseLogger.logLevel = .debug
        self.baseLogger = baseLogger
        self.logger = SeerLogger(baseLogger)
        self.sinatra = Sinatra(logger: baseLogger)
        self.gita = Gita(logger: baseLogger)
        self.documentCache = DocumentCache()

        let identity = NodeIdentity.load(logger: baseLogger)
        self.nodeId = identity.nodeId

        self.registryMutator = RegistryMutator(logger: SeerLogger(baseLogger))
    }

    func shutdown() async {
        await registryMutator.flushForShutdown()
    }

    /// Handle a chat request.
    nonisolated func handleChat(request: ChatCompletionRequest,
                    modelProvider: ModelProvider,
                    seerRequest: SeerRequest? = nil,
                    queryExpansion: Bool = false) async throws -> ChatResult {

        let seerRequest = seerRequest ?? request.seer
        var messages: [[String: Any]] = []

        guard let recentMessage = request.messages.last(where: {
            $0.role == .user
        }) else {
            logger.info("Handle Chat", "Could not find last user message.", service: .seer, request: seerRequest, flow: .chat)
            return .init(
                input: UserInput(
                    messages: messages
                ),
                references: [],
                contribution: nil,
                tone: nil,
                autoMemory: false
            )
        }

        for message in request.messages {
            guard message.content.asString != recentMessage.content.asString else { continue }
            var entry: [String: Any] = [
                MessageProcessingKeys.role: message.role.rawValue,
                MessageProcessingKeys.content: message.content.asString ?? "",
            ]
            if let ts = message.timestamp {
                entry[MessageProcessingKeys.timestamp] = ts
            }
            messages.append(entry)
        }

        /* Sinatra */
        let capturedMessages = request.messages
        let capturedSeerRequest = seerRequest
        let sinatraTask = Task<Sinatra.PrepareResult?, any Error> {
            try await sinatra.prepare(capturedMessages,
                                      request: capturedSeerRequest,
                                      modelProvider: modelProvider)
        }

        /* Search */
        let searchStartNs = DispatchTime.now().uptimeNanoseconds
        let result: SearchChatResult
        if _totemQueryClient != nil {
            logger.debug("Handle Totem Chat", "🌬️ Searching via Totem fan-out, scope: \(seerRequest.scope?.rawValue ?? ""), aggregate: \(seerRequest.aggregate == true)", service: .seer, request: seerRequest)
            result = try await searchWithTotems(
                recentMessage.content.asString,
                request: seerRequest
            )
        } else if queryExpansion, let messageContent = recentMessage.content.asString {
            let expansion = expandQuery(
                messageContent,
                conversationHistory: messages,
                request: seerRequest
            )
            logger.debug("Handle Chat", "🌬️ Searching..., scope: \(seerRequest.scope?.rawValue ?? ""), variants: \(expansion.all.count), aggregate: \(seerRequest.aggregate == true)", service: .seer, request: seerRequest)
            result = try await searchExpanded(
                expansion,
                request: seerRequest
            )
        } else {
            logger.debug("Handle Chat", "🌬️ Searching..., scope: \(seerRequest.scope?.rawValue ?? ""), aggregate: \(seerRequest.aggregate == true)", service: .seer, request: seerRequest)
            result = try await search(
                recentMessage.content.asString,
                request: seerRequest
            )
        }
        let searchElapsedNs = DispatchTime.now().uptimeNanoseconds - searchStartNs
        SeerMetrics.totemSearchDuration.recordNanoseconds(Int64(searchElapsedNs))
        logger.info("Timing", "[timing] search \(searchElapsedNs / 1_000_000)ms (\(result.partitions.count) partitions)", service: .seer, request: seerRequest, flow: .chat)

        /* Personality (persona voice + params + optional model override) */
        let personality = PersonalityStore.personality(id: request.personality)

        // A Bonnie client reframes retrieval as SUPPORT: background that helps
        // the current request, never material that redirects it — plus its own
        // tool-action deposits get a separate "past actions" tier.
        let isBonnieClient = request.client?.lowercased() == "bonnie"

        /* Additional Instructions */
        let baseRules = "Keep responses under 6-7 sentences. Be specific and grounded. Never announce that you are an AI. Never output XML-like tags (such as <external>) in your response."
        let instructions: String
        if let additionalInstructions = request.instructions {
            instructions = """
            --- CONVERSATIONAL INSTRUCTIONS ---
            \(additionalInstructions)

            \(baseRules)
            """
        } else {
            instructions = baseRules
        }

        /* Personalized Context */
        let context: String
        var compactCitations: [Gita.CompactCitation] = []
        var sourceIndex: [Int: DocumentID] = [:]
        var usedVerbatimContext = false

        if result.context.isEmpty == false {
            let compactStartNs = DispatchTime.now().uptimeNanoseconds
            let compacted = try await compact(
                messages: messages,
                partitions: result.partitions,
                modelProvider: modelProvider,
                request: seerRequest,
                bonnieClient: isBonnieClient
            )
            let compactElapsedNs = DispatchTime.now().uptimeNanoseconds - compactStartNs
            SeerMetrics.compactDuration.recordNanoseconds(Int64(compactElapsedNs))
            logger.info("Timing", "[timing] compact \(compactElapsedNs / 1_000_000)ms (verbatim: \(compacted.usedVerbatim))", service: .seer, request: seerRequest, flow: .chat)
            compactCitations = compacted.citations
            sourceIndex = compacted.sourceIndex
            usedVerbatimContext = compacted.usedVerbatim

            // Citation-marker protocol: the model cites bracketed sources with
            // invisible [[n]] markers that we resolve into exact spans.
            var citationProtocol = """
            - The [n] tags label the sources in the context above; leave them there — do not copy [n] tags into your reply. Instead, when a sentence of yours draws on source [n], end that sentence with its doubled-bracket marker [[n]], placed after the closing punctuation (several in a row are fine, e.g. [[1]][[3]]). The markers are machine-read and stripped before the user sees your reply — never mention or explain them, and never use a number that does not appear in the context. This is a simple mechanical rule; apply it without deliberation.
            """
            if personality?.citationEmphasis == true {
                citationProtocol += "\n            - Marker discipline is essential: every sentence that uses retrieved material must carry its [[n]] marker. Sentences that are purely your own reasoning carry none."
            }

            context = """
            --- CONTEXT ---
            \(compacted.text)

            \(Self.contextUsageGuide(bonnieClient: isBonnieClient, citationProtocol: citationProtocol))
            ---
            """
        } else {
            context = ""
        }

        let memoryInstruction = Self.memoryInstruction(
            contextEmpty: context.isEmpty, bonnieClient: isBonnieClient)

        // The persona voice: personality fragment when selected, classic confidante otherwise.
        let voice = personality?.systemFragment
            ?? "You are a close confidante — honest, warm, and direct. Offer your honest perspective, not just a reflection of what they already said."

        let personalizedContext: String = """
        Your name is \(personality?.name ?? "Seer").

        \(voice) \(memoryInstruction)

        \(instructions)

        \(context)
        """

        logger.info(
            "Sinatra Adjustments",
            "⚜️ \(zip(result.context, result.adjustments).enumerated().map { "[\($0.offset)] pqThreshold: \(String(format: "%.4f", $0.element.1.pqDistanceThreshold)) → \($0.element.0.prefix(120))…" }.joined(separator: "\n"))",
            service: .sinatra,
            request: seerRequest,
            externalOnly: true,
            flow: .chat
        )

        let tone = SinatraTone.from(result.adjustments)

        let searchEntries = result.adjustments.flatMap(\.entries)
        if !searchEntries.isEmpty {
            let searchOwner = SeerRegistry.Owner(id: seerRequest.ownerId)
            sinatra.updateRegistry { $0.lastSearchEntries[searchOwner] = searchEntries }
        }
        logger.info(
            "Sinatra Tone",
            "⚜️ temperature: \(String(format: "%.4f", tone.temperature)), topP: \(String(format: "%.4f", tone.topP)), repetitionPenalty: \(String(format: "%.4f", tone.repetitionPenalty)), repetitionContextSize: \(tone.repetitionContextSize)",
            service: .sinatra,
            request: seerRequest,
            flow: .chat
        )

        // Verbatim context carries no conversation summary (the briefing's
        // "Conversation History" section), so the history must reach the model
        // as real message turns — capped to the most recent 10. The briefing
        // path keeps the original two-message shape: history lives inside the
        // compacted text.
        let historyTurns: [[String: Any]] = usedVerbatimContext ? Array(messages.suffix(10)) : []
        let finalMessages: [[String: Any]] = historyTurns + [
            [
                MessageProcessingKeys.role: ChatMessageRequestRole.user.rawValue,
                MessageProcessingKeys.content: recentMessage.content.asString ?? "",
            ],
            [
                MessageProcessingKeys.role: ChatMessageRequestRole.system.rawValue,
                MessageProcessingKeys.content: personalizedContext,
            ]
        ]

        /* Auto Memory */
        let userMessageCount = request.messages.filter { $0.role == .user }.count
        let owner = SeerRegistry.Owner(id: seerRequest.ownerId)

        let policy = Self.autoMemoryPolicy
        let firedTriggers: Set<AutoMemoryTrigger> = {
            var fired = Set<AutoMemoryTrigger>()
            for trigger in policy.triggers {
                switch trigger {
                case .messageCount(let threshold):
                    if userMessageCount > 0 && userMessageCount % threshold == 0 {
                        fired.insert(trigger)
                    }
                case .topicChange:
                    if sinatra.registry?.lastTrajectories[owner]?.sessionBoundaryDetected == true {
                        fired.insert(trigger)
                    }
                }
            }
            return fired
        }()

        let activeTriggers = firedTriggers.intersection(policy.triggers)
        let didTriggerAutoMemory: Bool = switch policy.mode {
        case .any: !activeTriggers.isEmpty
        case .all: activeTriggers == policy.triggers
        }

        if didTriggerAutoMemory {
            let capturedMessages = messages
            let capturedRecent = recentMessage.content.asString ?? ""
            let capturedRequest = seerRequest
            let triggerReason = activeTriggers
                .map { trigger in
                    switch trigger {
                    case .messageCount: return "messageCount(\(userMessageCount))"
                    case .topicChange:  return "topicChange"
                    }
                }
                .sorted()
                .joined(separator: ", ")
            logger.debug("Auto Memory", "🌬️ Triggered auto memory — reason: \(triggerReason)", service: .seer, request: seerRequest)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.autoMemorize(
                        messages: capturedMessages,
                        recentMessage: capturedRecent,
                        request: capturedRequest,
                        modelProvider: modelProvider
                    )
                } catch {
                    self.logger.warning(
                        "💾 Auto-memory snapshot failed for owner \(capturedRequest.ownerId): \(error)",
                        service: .seer,
                        request: capturedRequest
                    )
                }
            }
        }

        return .init(
            input: UserInput(
                messages: finalMessages
            ),
            references: result.references,
            partitions: result.partitions,
            compactCitations: compactCitations,
            sourceIndex: sourceIndex,
            personality: personality,
            contribution: result.contribution,
            tone: tone,
            autoMemory: didTriggerAutoMemory,
            sinatraTask: sinatraTask
        )
    }
}

extension Seer {
    nonisolated func user(for id: String) -> Seer.User {
        Seer.User(groups: [])
    }
}

// MARK: - Nonisolated mutator access (safe: let constants of Sendable actor types)

extension Seer {
    /// Exposes the registry mutator from a nonisolated context.
    /// Safe because `registryMutator` is a `let` constant whose type is a `Sendable` actor.
    nonisolated var nonisolatedRegistryMutator: RegistryMutator { registryMutator }

    /// Returns the Gita wallet for the given owner.
    /// Called with `await` from route handlers so Gita access stays actor-isolated.
    func gitaWallet(for ownerId: String) -> Gita.Wallet {
        gita.walletRegistry.wallet(for: ownerId)
    }
}

// MARK: - Write queue public API

extension Seer {
    private static let maxCoalesceItems = 100

    /// Enqueue a batch-put job. Returns immediately; the job runs when the queue drains to it.
    func enqueuePut(_ items: [Seer.BatchPutItem], request: SeerRequest) {
        enqueue(.put(items, request))
    }

    /// Enqueue a batch-remove job. Returns immediately; the job runs when the queue drains.
    func enqueueRemoveBatch(_ items: [(documentId: String, ownerId: String)]) {
        enqueue(.removeBatch(items))
    }

    /// Enqueue a remove-all job and suspend until it completes.
    /// Returns the number of documents removed, even when earlier jobs are still queued.
    func removeAll(ownerId: String, request: SeerRequest) async -> Int {
        await withCheckedContinuation { continuation in
            enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
        }
    }

    private func enqueue(_ job: WriteJob) {
        pending.append(job)
        SeerMetrics.indexQueueDepth.record(Double(pending.count))
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            if case .put(let firstItems, let baseReq) = pending[0] {
                var merged   = firstItems
                var consumed = 1
                while consumed < pending.count && merged.count < Self.maxCoalesceItems {
                    guard case .put(let nextItems, let nextReq) = pending[consumed],
                          nextReq.ownerId == baseReq.ownerId,
                          nextReq.group?.id == baseReq.group?.id else { break }
                    merged.append(contentsOf: nextItems)
                    consumed += 1
                }
                pending.removeFirst(consumed)
                SeerMetrics.indexQueueDepth.record(Double(pending.count))
                await execute(.put(merged, baseReq))
            } else {
                let job = pending.removeFirst()
                SeerMetrics.indexQueueDepth.record(Double(pending.count))
                await execute(job)
            }
        }
        SeerMetrics.indexQueueDepth.record(0)
        isProcessing = false
    }

    private func execute(_ job: WriteJob) async {
        switch job {
        case .put(let items, let request):
            await putBatch(items, request: request)

        case .removeBatch(let items):
            await _removeBatch(items: items)

        case .removeAll(let ownerId, let request, let continuation):
            let count = await _removeAll(ownerId: ownerId, request: request)
            continuation.resume(returning: count)
        }
    }
}
