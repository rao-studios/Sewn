//
//  RealtimeTurnEngine.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 7/22/26.
//

import Foundation
import Logging

/// Orchestrates one realtime turn: an instant "opening" pass streamed from
/// conversation history alone (fast non-thinking model) while retrieval runs
/// concurrently, then a "grounded" continuation on the primary model over the
/// retrieved context, with server-side TTS interleaved sentence-by-sentence.
///
/// All provider work arrives as injected closures (`Deps`) so the engine is
/// fully scriptable offline; all outbound frames flow through a single writer
/// loop so frame order on the socket is deterministic per producer.
struct RealtimeTurnEngine {
    struct Deps {
        /// Opening pass: fast streaming model over plain role/content messages.
        var opening: @Sendable ([[String: String]]) async throws -> AsyncThrowingStream<StreamDelta, Error>
        /// Retrieval: the full existing chat pipeline (search + compact +
        /// prompt assembly + auto-memory). Runs concurrently with the opening.
        var retrieval: @Sendable () async throws -> ChatResult
        /// Grounded pass: the primary chat model over the assembled prompt.
        var grounded: @Sendable (UserInput.Prompt) async throws -> AsyncThrowingStream<StreamDelta, Error>
        /// Sentence TTS: text in, PCM deltas out (f32 LE mono 24 kHz).
        var tts: @Sendable (String) async throws -> AsyncThrowingStream<Data, Error>
    }

    struct Summary {
        var openingText = ""
        /// Grounded model output including [[n]] markers (for span annotation).
        var groundedRaw = ""
        /// User-visible text across both phases (markers stripped).
        var accumulatedText = ""
        var chatResult: ChatResult?
        var ttsFailed = false
        var firstTokenMs: Int?
        var firstAudioMs: Int?
        var retrievalWaitMs: Int?
    }

    enum EngineError: Error {
        case noSummary
    }

    /// Continue the opening mid-message via assistant prefill. Constant switch:
    /// if Inkling's thinking phase misbehaves under prefill, flip to `false`
    /// and a "Continue your reply." user nudge is appended instead.
    static let useAssistantPrefill = true

    static let seamInstruction = """
    The assistant text already streamed to the user is the opening of your reply — continue it seamlessly. \
    Never restate it, never contradict it, never greet again; pick up exactly where it left off.
    """

    static let degradedInstruction = """
    Retrieval is unavailable for this turn. Answer fully from the conversation alone — do not reference, \
    invent, or imply retrieved memories or documents.
    """

    let deps: Deps
    let openingSystemPrompt: String
    /// Raw role/content history including the recent user message, no system turns.
    let historyMessages: [[String: String]]
    let logger: Logger

    /// Runs the turn, emitting frames through `send`. `send` failures (client
    /// closed the socket) cancel all in-flight work and rethrow.
    func run(send: @escaping @Sendable (RealtimeOutbound) async throws -> Void) async throws -> Summary {
        let (frames, frameCont) = AsyncStream<RealtimeOutbound>.makeStream()
        let summaryBox = LockedValue<Summary?>(nil)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await frame in frames {
                    try await send(frame)
                }
            }
            group.addTask {
                defer { frameCont.finish() }
                let summary = try await orchestrate { frameCont.yield($0) }
                summaryBox.withLock { $0 = summary }
            }
            do {
                try await group.waitForAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }

        guard let summary = summaryBox.withLock({ $0 }) else { throw EngineError.noSummary }
        return summary
    }

    // MARK: - Orchestration

    private func orchestrate(emit: @escaping @Sendable (RealtimeOutbound) -> Void) async throws -> Summary {
        let startNs = DispatchTime.now().uptimeNanoseconds
        func elapsedMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000) }

        var summary = Summary()

        // Retrieval starts immediately and runs under the opening.
        let retrievalDeps = deps
        let retrievalTask = Task { try await retrievalDeps.retrieval() }
        defer { retrievalTask.cancel() }

        // ── TTS lane: one sequential worker keeps audio frames ordered ──────
        let (sentences, sentenceCont) = AsyncStream<String>.makeStream()
        let firstAudioMsBox = LockedValue<Int?>(nil)
        let ttsLane = Task { () -> Bool in
            var announced = false
            do {
                for await sentence in sentences {
                    try Task.checkCancellation()
                    let pcmStream = try await deps.tts(sentence)
                    for try await pcm in pcmStream {
                        if !announced {
                            announced = true
                            firstAudioMsBox.withLock { $0 = elapsedMs() }
                            emit(.audioBegin(sampleRate: MistralTTS.sampleRate, channels: 1, bits: 32))
                        }
                        emit(.pcm(pcm))
                    }
                }
                return true
            } catch is CancellationError {
                return true
            } catch {
                logger.warning("[realtime] TTS lane failed: \(error) — text continues without audio")
                emit(.ttsFailed)
                return false
            }
        }
        defer { ttsLane.cancel() }

        func speak(_ text: String, chunker: inout StreamingSentenceChunker, flush: Bool = false) {
            let chunks = flush
                ? (chunker.flushRemainder().map { [$0] } ?? [])
                : chunker.feed(text)
            for chunk in chunks {
                let clean = TTSTextSanitizer.sanitize(chunk)
                if !clean.isEmpty { sentenceCont.yield(clean) }
            }
        }

        // ── Pass 1: opening from history alone ──────────────────────────────
        emit(.phase(.opening))
        var chunker = StreamingSentenceChunker()
        var openingFailed = false
        do {
            let openingMessages = [["role": "system", "content": openingSystemPrompt]] + historyMessages
            for try await delta in try await deps.opening(openingMessages) {
                guard let content = delta.content, !content.isEmpty else { continue }
                if summary.firstTokenMs == nil { summary.firstTokenMs = elapsedMs() }
                summary.openingText += content
                summary.accumulatedText += content
                emit(.token(.opening, content))
                speak(content, chunker: &chunker)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Opening is an optimization — never the turn. Fall through to a
            // grounded-only turn (the classic shape, minus the SSE transport).
            openingFailed = true
            summary.openingText = ""
            logger.warning("[realtime] opening pass failed: \(error) — grounded-only turn")
        }
        // A cancelled AsyncThrowingStream ends iteration EMPTY rather than
        // throwing — convert graceful-empty-on-cancel into a real abort so a
        // client close never produces a phantom completed turn.
        try Task.checkCancellation()
        speak("", chunker: &chunker, flush: true)
        let openingDoneMs = elapsedMs()
        logger.info("[timing] realtime opening \(openingDoneMs)ms")

        // ── Retrieval joins ──────────────────────────────────────────────────
        // Task.value ignores the awaiting task's cancellation; the handler
        // forwards it so a client close doesn't pin the turn to the 30s
        // search timeout.
        let chatResult = await withTaskCancellationHandler {
            try? await retrievalTask.value
        } onCancel: {
            retrievalTask.cancel()
        }
        summary.chatResult = chatResult
        summary.retrievalWaitMs = elapsedMs() - openingDoneMs
        if chatResult == nil {
            SewnMetrics.realtimeRetrievalFailures.increment()
            logger.warning("[realtime] retrieval failed — degraded grounded pass")
        }
        logger.info("[timing] realtime retrieval_wait \(summary.retrievalWaitMs ?? 0)ms")

        // ── Pass 2: grounded continuation ────────────────────────────────────
        emit(.phase(.grounded))
        var groundedChunker = StreamingSentenceChunker()
        var markerFilter = Gita.MarkerStreamFilter()
        do {
            let prompt = groundedPrompt(
                chatResult: chatResult,
                openingText: openingFailed ? nil : summary.openingText
            )
            for try await delta in try await deps.grounded(prompt) {
                guard let content = delta.content, !content.isEmpty else { continue }
                if summary.firstTokenMs == nil { summary.firstTokenMs = elapsedMs() }
                summary.groundedRaw += content
                let visible = markerFilter.feed(content)
                guard !visible.isEmpty else { continue }
                summary.accumulatedText += visible
                emit(.token(.grounded, visible))
                speak(visible, chunker: &groundedChunker)
            }
            let tail = markerFilter.finish()
            if !tail.isEmpty {
                summary.accumulatedText += tail
                emit(.token(.grounded, tail))
                speak(tail, chunker: &groundedChunker)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The opening already spoke; surface the failure but let the turn
            // complete so the client keeps what it has.
            emit(.error(stage: "grounded", message: "\(error)"))
            logger.error("[realtime] grounded pass failed: \(error)")
        }
        try Task.checkCancellation()
        speak("", chunker: &groundedChunker, flush: true)

        // ── Drain audio, then report ─────────────────────────────────────────
        sentenceCont.finish()
        summary.ttsFailed = !(await ttsLane.value)
        summary.firstAudioMs = firstAudioMsBox.withLock { $0 }
        logger.info("[timing] realtime turn \(elapsedMs())ms (first_token \(summary.firstTokenMs ?? -1)ms, first_audio \(summary.firstAudioMs ?? -1)ms)")
        return summary
    }

    /// Pass-2 prompt: the retrieval pipeline's own message assembly, extended
    /// with the seam instruction and the opening as an assistant prefill so
    /// the model continues mid-reply instead of starting over.
    private func groundedPrompt(chatResult: ChatResult?, openingText: String?) -> UserInput.Prompt {
        var messages: [[String: Any]]
        if let chatResult, case .messages(let assembled) = chatResult.input.prompt {
            messages = assembled
        } else {
            messages = historyMessages.map {
                [
                    MessageProcessingKeys.role: $0["role"] ?? "user",
                    MessageProcessingKeys.content: $0["content"] ?? "",
                ]
            }
            messages.append([
                MessageProcessingKeys.role: ChatMessageRequestRole.system.rawValue,
                MessageProcessingKeys.content: Self.degradedInstruction,
            ])
        }
        if let openingText, !openingText.isEmpty {
            messages.append([
                MessageProcessingKeys.role: ChatMessageRequestRole.system.rawValue,
                MessageProcessingKeys.content: Self.seamInstruction,
            ])
            messages.append([
                MessageProcessingKeys.role: ChatMessageRequestRole.assistant.rawValue,
                MessageProcessingKeys.content: openingText,
            ])
            if !Self.useAssistantPrefill {
                messages.append([
                    MessageProcessingKeys.role: ChatMessageRequestRole.user.rawValue,
                    MessageProcessingKeys.content: "Continue your reply.",
                ])
            }
        }
        return UserInput(messages: messages).prompt
    }
}

