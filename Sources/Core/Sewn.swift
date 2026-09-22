//
//  Sewn.swift
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
import RaoStack

actor Sewn {
    internal let logger: SewnLogger
    internal let baseLogger: Logger
    internal let sinatra: Sinatra
    internal let gita: Gita
    internal let registryMutator: RegistryMutator
    let documentCache: DocumentCache

    /// Persistent node identity for this Sewn instance.
    let nodeId: UUID

    /// How this Sewn's local stack is secured, decided once at start: open
    /// (hosted, dev), one app's secret, or every app's on a shared ~/.rao
    /// stack — where it also decides which Threads a request may reach.
    nonisolated let stack: StackMode

    /// Type-erased ThreadQueryClient (cast to ThreadQueryClient where needed).
    /// Stored as Sendable to keep the actor's stored properties isolation-clean.
    nonisolated(unsafe) var _threadQueryClient: (any Sendable)?

    // MARK: - Write queue (serialises all index mutations through a single FIFO drain)
    //
    // All insertions and deletions are routed through this queue so they never overlap.
    // The actor's isolation prevents concurrent access to `pending` and `isProcessing`.
    // When drain() is suspended awaiting a mutator, new enqueue() calls only append to
    // `pending[]` — they do NOT execute because `isProcessing` blocks a second drain.
    // This preserves the ordering guarantee: no removeAll can interleave mid-putBatch.
    // Every job carries its SewnRequest, and with it the caller app its fan-out is
    // scoped to; puts only coalesce when they act for the same app (`canCoalesce`).

    private enum WriteJob {
        case put([Sewn.BatchPutItem], SewnRequest)
        case removeAll(ownerId: String, request: SewnRequest, CheckedContinuation<Int, Never>)
    }
    private var pending: [WriteJob] = []
    private var isProcessing = false

    init(stack: StackMode = .open) {
        self.stack = stack
        var baseLogger = Logger(label: "sewn-logger")
        baseLogger.logLevel = .debug
        self.baseLogger = baseLogger
        self.logger = SewnLogger(baseLogger)
        self.sinatra = Sinatra(logger: baseLogger)
        self.gita = Gita(logger: baseLogger)
        self.documentCache = DocumentCache()

        let identity = NodeIdentity.load(logger: baseLogger)
        self.nodeId = identity.nodeId

        self.registryMutator = RegistryMutator(logger: SewnLogger(baseLogger))
    }

    func shutdown() async {
        await registryMutator.flushForShutdown()
    }

    /// Handle a chat request.
    nonisolated func handleChat(request: ChatCompletionRequest,
                    modelProvider: ModelProvider,
                    sewnRequest: SewnRequest? = nil,
                    queryExpansion: Bool = false) async throws -> ChatResult {
        // The turn's backend, for every pass that reads the user's words.
        let provider = request.provider ?? .serverDefault

        let sewnRequest = sewnRequest ?? request.sewn
        var messages: [[String: Any]] = []

        guard let recentMessage = request.messages.last(where: {
            $0.role == .user
        }) else {
            logger.info("Handle Chat", "Could not find last user message.", service: .sewn, request: sewnRequest, flow: .chat)
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
        let capturedSewnRequest = sewnRequest
        let sinatraTask = Task<Sinatra.PrepareResult?, any Error> {
            try await sinatra.prepare(capturedMessages,
                                      request: capturedSewnRequest,
                                      modelProvider: modelProvider,
                                      provider: provider)
        }

        /* Search */
        let searchStartNs = DispatchTime.now().uptimeNanoseconds
        let result: SearchChatResult
        if _threadQueryClient != nil {
            logger.debug("Handle Thread Chat", "🌬️ Searching via Thread fan-out, scope: \(sewnRequest.scope?.rawValue ?? ""), aggregate: \(sewnRequest.aggregate == true)", service: .sewn, request: sewnRequest)
            result = try await searchWithThreads(
                recentMessage.content.asString,
                request: sewnRequest
            )
        } else if queryExpansion, let messageContent = recentMessage.content.asString {
            let expansion = expandQuery(
                messageContent,
                conversationHistory: messages,
                request: sewnRequest
            )
            logger.debug("Handle Chat", "🌬️ Searching..., scope: \(sewnRequest.scope?.rawValue ?? ""), variants: \(expansion.all.count), aggregate: \(sewnRequest.aggregate == true)", service: .sewn, request: sewnRequest)
            result = try await searchExpanded(
                expansion,
                request: sewnRequest
            )
        } else {
            logger.debug("Handle Chat", "🌬️ Searching..., scope: \(sewnRequest.scope?.rawValue ?? ""), aggregate: \(sewnRequest.aggregate == true)", service: .sewn, request: sewnRequest)
            result = try await search(
                recentMessage.content.asString,
                request: sewnRequest
            )
        }
        let searchElapsedNs = DispatchTime.now().uptimeNanoseconds - searchStartNs
        SewnMetrics.threadSearchDuration.recordNanoseconds(Int64(searchElapsedNs))
        logger.info("Timing", "[timing] search \(searchElapsedNs / 1_000_000)ms (\(result.partitions.count) partitions)", service: .sewn, request: sewnRequest, flow: .chat)

        /* Personality (persona voice + params + optional model override).
           An inline `persona` is the client's own name and voice — Mary
           would otherwise inherit "Your name is Sewn" from the default. */
        let personality = PersonalityStore.personality(id: request.personality)
        let persona = resolveChatPersona(inline: request.persona, stored: personality)

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
                request: sewnRequest,
                bonnieClient: isBonnieClient,
                provider: provider
            )
            let compactElapsedNs = DispatchTime.now().uptimeNanoseconds - compactStartNs
            SewnMetrics.compactDuration.recordNanoseconds(Int64(compactElapsedNs))
            logger.info("Timing", "[timing] compact \(compactElapsedNs / 1_000_000)ms (verbatim: \(compacted.usedVerbatim))", service: .sewn, request: sewnRequest, flow: .chat)
            compactCitations = compacted.citations
            sourceIndex = compacted.sourceIndex
            usedVerbatimContext = compacted.usedVerbatim

            // Citation-marker protocol: the model cites bracketed sources with
            // invisible [[n]] markers that we resolve into exact spans.
            var citationProtocol = """
            - The [n] tags label the sources in the context above; leave them there — do not copy [n] tags into your reply. Instead, when a sentence of yours draws on source [n], end that sentence with its doubled-bracket marker [[n]], placed after the closing punctuation (several in a row are fine, e.g. [[1]][[3]]). The markers are machine-read and stripped before the user sees your reply — never mention or explain them, and never use a number that does not appear in the context. This is a simple mechanical rule; apply it without deliberation.
            """
            if persona.citationEmphasis {
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

        let personalizedContext: String = """
        \(chatPersonaSection(persona, memoryInstruction: memoryInstruction))

        \(instructions)

        \(context)
        """

        logger.info(
            "Sinatra Adjustments",
            "⚜️ \(zip(result.context, result.adjustments).enumerated().map { "[\($0.offset)] pqThreshold: \(String(format: "%.4f", $0.element.1.pqDistanceThreshold)) → \($0.element.0.prefix(120))…" }.joined(separator: "\n"))",
            service: .sinatra,
            request: sewnRequest,
            externalOnly: true,
            flow: .chat
        )

        let tone = SinatraTone.from(result.adjustments)

        let searchEntries = result.adjustments.flatMap(\.entries)
        if !searchEntries.isEmpty {
            let searchOwner = SewnRegistry.Owner(id: sewnRequest.ownerId)
            sinatra.updateRegistry { $0.lastSearchEntries[searchOwner] = searchEntries }
        }
        logger.info(
            "Sinatra Tone",
            "⚜️ temperature: \(String(format: "%.4f", tone.temperature)), topP: \(String(format: "%.4f", tone.topP)), repetitionPenalty: \(String(format: "%.4f", tone.repetitionPenalty)), repetitionContextSize: \(tone.repetitionContextSize)",
            service: .sinatra,
            request: sewnRequest,
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
        let owner = SewnRegistry.Owner(id: sewnRequest.ownerId)

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
            let capturedRequest = sewnRequest
            let triggerReason = activeTriggers
                .map { trigger in
                    switch trigger {
                    case .messageCount: return "messageCount(\(userMessageCount))"
                    case .topicChange:  return "topicChange"
                    }
                }
                .sorted()
                .joined(separator: ", ")
            logger.debug("Auto Memory", "🌬️ Triggered auto memory — reason: \(triggerReason)", service: .sewn, request: sewnRequest)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.autoMemorize(
                        messages: capturedMessages,
                        recentMessage: capturedRecent,
                        request: capturedRequest,
                        modelProvider: modelProvider,
                        provider: provider
                    )
                } catch {
                    self.logger.warning(
                        "💾 Auto-memory snapshot failed for owner \(capturedRequest.ownerId): \(error)",
                        service: .sewn,
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

extension Sewn {
    nonisolated func user(for id: String) -> Sewn.User {
        Sewn.User(groups: [])
    }
}

// MARK: - Caller scope

extension Sewn {
    /// The Thread nodes a request acting for `app` may reach. Open and one-app
    /// stacks have one caller, so every node. A shared stack reaches only the
    /// caller's own app's nodes — and none for a request that lost its app on
    /// the way, which is a bug worth a log line, never a reason to guess.
    nonisolated func nodeScope(for app: RaoApp?) -> NodeScope {
        guard case .multiApp = stack else { return .all }
        guard let app else {
            logger.warning(
                label: "Node Scope",
                "Shared stack: a Thread fan-out ran for no app — it reaches no Thread",
                service: .sewn)
            return .none
        }
        return .app(app)
    }
}

// MARK: - Nonisolated mutator access (safe: let constants of Sendable actor types)

extension Sewn {
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

extension Sewn {
    private static let maxCoalesceItems = 100

    /// Enqueue a batch-put job. Returns immediately; the job runs when the queue drains to it.
    func enqueuePut(_ items: [Sewn.BatchPutItem], request: SewnRequest) {
        enqueue(.put(items, request))
    }

    /// Enqueue a remove-all job and suspend until it completes.
    /// Returns the number of documents removed, even when earlier jobs are still queued.
    func removeAll(ownerId: String, request: SewnRequest) async -> Int {
        await withCheckedContinuation { continuation in
            enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
        }
    }

    private func enqueue(_ job: WriteJob) {
        pending.append(job)
        SewnMetrics.indexQueueDepth.record(Double(pending.count))
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.drain() }
    }

    /// Whether a queued put may ride in the batch of the put ahead of it. A
    /// merged batch is indexed as `base` — one owner, one group, one Thread —
    /// so `next` must match on all three, and on a shared stack that Thread
    /// must belong to the app both act for.
    static func canCoalesce(_ next: SewnRequest, into base: SewnRequest) -> Bool {
        next.ownerId == base.ownerId
            && next.group?.id == base.group?.id
            && next.callerApp == base.callerApp
    }

    private func drain() async {
        while !pending.isEmpty {
            if case .put(let firstItems, let baseReq) = pending[0] {
                var merged   = firstItems
                var consumed = 1
                while consumed < pending.count && merged.count < Self.maxCoalesceItems {
                    guard case .put(let nextItems, let nextReq) = pending[consumed],
                          Self.canCoalesce(nextReq, into: baseReq) else { break }
                    merged.append(contentsOf: nextItems)
                    consumed += 1
                }
                pending.removeFirst(consumed)
                SewnMetrics.indexQueueDepth.record(Double(pending.count))
                await execute(.put(merged, baseReq))
            } else {
                let job = pending.removeFirst()
                SewnMetrics.indexQueueDepth.record(Double(pending.count))
                await execute(job)
            }
        }
        SewnMetrics.indexQueueDepth.record(0)
        isProcessing = false
    }

    private func execute(_ job: WriteJob) async {
        switch job {
        case .put(let items, let request):
            await putBatch(items, request: request)

        case .removeAll(let ownerId, let request, let continuation):
            let count = await _removeAll(ownerId: ownerId, request: request)
            continuation.resume(returning: count)
        }
    }
}
