//
//  RealtimeTests.swift
//  seer-serverTests
//
//  Streaming sentence chunker, realtime wire frames, and the two-phase turn
//  engine with fully scripted providers — no network anywhere.
//

import XCTest
@testable import seer_server
import Logging

// MARK: - StreamingSentenceChunker

final class StreamingSentenceChunkerTests: XCTestCase {

    func testFirstSentenceFlushesAloneAcrossDeltas() {
        var chunker = StreamingSentenceChunker()
        XCTAssertEqual(chunker.feed("Hello wor"), [])
        XCTAssertEqual(chunker.feed("ld. Next thing"), ["Hello world."])
    }

    func testSubsequentSentencesBatchInPairs() {
        var chunker = StreamingSentenceChunker()
        _ = chunker.feed("First. And")                       // emits First.
        let chunks = chunker.feed(" one. Two here. Three starts")
        XCTAssertEqual(chunks, ["And one. Two here."])
    }

    func testTerminatorAtBufferEndIsHeld() {
        var chunker = StreamingSentenceChunker()
        XCTAssertEqual(chunker.feed("Done."), [])
        XCTAssertEqual(chunker.flushRemainder(), "Done.")
    }

    func testWordCapForcesEmit() {
        var chunker = StreamingSentenceChunker()
        _ = chunker.feed("Start. ")                          // emits Start.
        let long = Array(repeating: "word", count: 35).joined(separator: " ") + ". Trailing"
        let chunks = chunker.feed(long)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasPrefix("word word"))
    }

    func testFlushRemainderJoinsPendingAndTail() {
        var chunker = StreamingSentenceChunker()
        _ = chunker.feed("One done. ")                       // emits One done.
        _ = chunker.feed("Two done. Tail without end")       // Two done. pending (batch of 2 incomplete)
        XCTAssertEqual(chunker.flushRemainder(), "Two done. Tail without end")
    }

    func testFlushRemainderEmptyWhenNothingPending() {
        var chunker = StreamingSentenceChunker()
        _ = chunker.feed("Complete. More")
        _ = chunker.flushRemainder()
        XCTAssertNil(chunker.flushRemainder())
    }

    func testSanitizerStripsMarkdown() {
        XCTAssertEqual(TTSTextSanitizer.sanitize("**Bold** and `code` and [link](https://x.y)"),
                       "Bold and code and link")
    }
}

// MARK: - Wire frames

final class RealtimeOpeningPromptTests: XCTestCase {

    func testOpeningPromptFramesSeerAsActor() {
        let prompt = realtimeOpeningSystemPrompt()
        XCTAssertTrue(prompt.hasPrefix("Your name is Seer."))
        // The opening pass is the first thing spoken and drops client
        // instructions, so it must carry the agentic framing itself.
        XCTAssertTrue(prompt.contains("You act through your tools"))
        XCTAssertTrue(prompt.contains("I'm adding that now"))
        XCTAssertTrue(prompt.contains("never explain how they would do it themselves"))
        // The old blanket anti-overpromise clause that chilled action
        // acknowledgment is scoped to retrieved facts now.
        XCTAssertFalse(prompt.contains("never promise results you have not seen"))
        XCTAssertTrue(prompt.contains("haven't confirmed yet"))
        // Still a lean opening.
        XCTAssertTrue(prompt.contains("one-to-two-sentence"))
    }
}

final class RealtimeWireTests: XCTestCase {

    private func text(_ frame: RealtimeOutbound) -> String? {
        if case .text(let s) = frame.payload { return s }
        return nil
    }

    func testTokenFrameEscapesJSON() throws {
        let frame = RealtimeOutbound.token(.opening, "He said \"hi\"\n")
        let json = try XCTUnwrap(text(frame))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "token")
        XCTAssertEqual(object["phase"] as? String, "opening")
        XCTAssertEqual(object["text"] as? String, "He said \"hi\"\n")
    }

    func testAudioBeginAnnouncesFormat() throws {
        let json = try XCTUnwrap(text(.audioBegin(sampleRate: 24_000, channels: 1, bits: 32)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(object["encoding"] as? String, "f32le")
    }

    func testPCMRidesBinary() {
        let payload = RealtimeOutbound.pcm(Data([1, 2, 3, 4])).payload
        guard case .binary(let data) = payload else { return XCTFail("expected binary") }
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
    }

    func testMetadataEmbedsChunkDecodableWithExistingCodable() throws {
        let chunk = ChatCompletionChunkResponse(
            id: "rt-1", model: "api-test", choices: [], references: [], autoMemory: true
        )
        let frame = RealtimeOutbound.metadata(chunkJSON: try JSONEncoder().encode(chunk))
        let json = try XCTUnwrap(text(frame))

        struct Probe: Decodable {
            let type: String
            let chunk: ChatCompletionChunkResponse
        }
        let probe = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        XCTAssertEqual(probe.type, "metadata")
        XCTAssertEqual(probe.chunk.id, "rt-1")
        XCTAssertTrue(probe.chunk.autoMemory)
        XCTAssertTrue(probe.chunk.choices.isEmpty)
    }

    func testTurnStartDecodesEmbeddedChatRequest() throws {
        let json = """
        {"type":"turn.start","tts":{"voice_id":"fr_marie_calm"},"request":{"messages":[{"role":"user","content":"hey"}],"stream":true,"seer":{"owner_id":"o1","personal_totem_id":"t1"}}}
        """
        let start = try JSONDecoder().decode(RealtimeTurnStart.self, from: Data(json.utf8))
        XCTAssertEqual(start.type, "turn.start")
        XCTAssertEqual(start.tts?.voiceId, "fr_marie_calm")
        XCTAssertEqual(start.request.seer.personalTotemId, "t1")
        XCTAssertEqual(start.request.messages.first?.content.asString, "hey")
    }
}

// MARK: - Turn engine (scripted deps)

final class RealtimeTurnEngineTests: XCTestCase {

    private struct TestError: Error {}

    private final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [RealtimeOutbound] = []
        func append(_ frame: RealtimeOutbound) {
            lock.lock(); defer { lock.unlock() }
            frames.append(frame)
        }
        var all: [RealtimeOutbound] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }
        /// Compact order signature, e.g. ["phase:opening","token","audio.begin","pcm",…]
        var signature: [String] {
            all.map { frame in
                switch frame {
                case .phase(let p):      return "phase:\(p.rawValue)"
                case .token:             return "token"
                case .audioBegin:        return "audio.begin"
                case .pcm:               return "pcm"
                case .ttsFailed:         return "tts.failed"
                case .metadata:          return "metadata"
                case .turnEnd:           return "turn.end"
                case .error:             return "error"
                }
            }
        }
        func tokens(phase: RealtimePhase) -> String {
            all.compactMap {
                if case .token(let p, let t) = $0, p == phase { return t }
                return nil
            }.joined()
        }
    }

    private static func stream(_ texts: [String], thenFail: Bool = false) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            for text in texts {
                continuation.yield(StreamDelta(role: nil, content: text))
            }
            if thenFail {
                continuation.finish(throwing: TestError())
            } else {
                continuation.finish()
            }
        }
    }

    private static func pcmStream(for sentence: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(sentence.utf8))
            continuation.finish()
        }
    }

    private static func chatResult(context: String = "CTX") -> ChatResult {
        ChatResult(
            input: UserInput(messages: [
                [MessageProcessingKeys.role: "user", MessageProcessingKeys.content: "the question"],
                [MessageProcessingKeys.role: "system", MessageProcessingKeys.content: context],
            ]),
            references: [],
            contribution: nil,
            tone: nil,
            autoMemory: false
        )
    }

    private func makeEngine(
        opening: @escaping @Sendable ([[String: String]]) async throws -> AsyncThrowingStream<StreamDelta, Error>,
        retrieval: @escaping @Sendable () async throws -> ChatResult,
        grounded: @escaping @Sendable (UserInput.Prompt) async throws -> AsyncThrowingStream<StreamDelta, Error>,
        tts: (@Sendable (String) async throws -> AsyncThrowingStream<Data, Error>)? = nil
    ) -> RealtimeTurnEngine {
        RealtimeTurnEngine(
            deps: .init(
                opening: opening,
                retrieval: retrieval,
                grounded: grounded,
                tts: tts ?? { Self.pcmStream(for: $0) }
            ),
            openingSystemPrompt: "OPENING BRIEF",
            historyMessages: [["role": "user", "content": "the question"]],
            logger: Logger(label: "realtime-tests")
        )
    }

    private func messages(from prompt: UserInput.Prompt) -> [[String: String]] {
        guard case .messages(let raw) = prompt else { return [] }
        return raw.compactMap { entry in
            guard let role = entry[MessageProcessingKeys.role] as? String,
                  let content = entry[MessageProcessingKeys.content] as? String else { return nil }
            return ["role": role, "content": content]
        }
    }

    func testFrameOrderAndSummaryOnHappyPath() async throws {
        let log = FrameLog()
        let engine = makeEngine(
            opening: { _ in Self.stream(["Sure — the answer is short. "]) },
            retrieval: { Self.chatResult() },
            grounded: { _ in Self.stream(["Grounded detail one.", " Grounded detail two."]) }
        )
        let summary = try await engine.run { log.append($0) }

        XCTAssertEqual(summary.openingText, "Sure — the answer is short. ")
        XCTAssertEqual(summary.accumulatedText,
                       "Sure — the answer is short. Grounded detail one. Grounded detail two.")
        XCTAssertNotNil(summary.chatResult)
        XCTAssertFalse(summary.ttsFailed)
        XCTAssertNotNil(summary.firstTokenMs)
        XCTAssertNotNil(summary.firstAudioMs)

        let signature = log.signature
        XCTAssertEqual(signature.first, "phase:opening")
        XCTAssertTrue(signature.contains("audio.begin"))
        XCTAssertTrue(signature.contains("phase:grounded"))
        // audio.begin precedes every pcm frame
        XCTAssertLessThan(try XCTUnwrap(signature.firstIndex(of: "audio.begin")),
                          try XCTUnwrap(signature.firstIndex(of: "pcm")))
        // opening tokens precede the grounded phase marker
        XCTAssertLessThan(try XCTUnwrap(signature.firstIndex(of: "token")),
                          try XCTUnwrap(signature.firstIndex(of: "phase:grounded")))
        // engine never emits turn-level frames — the route owns those
        XCTAssertFalse(signature.contains("metadata"))
        XCTAssertFalse(signature.contains("turn.end"))
    }

    func testRetrievalOverlapsOpening() async throws {
        // Opening takes ~300ms to stream; retrieval takes ~350ms from ITS
        // start. If the engine serialized them, retrieval_wait would be the
        // full ~350ms after the opening; overlap leaves only the ~50ms
        // remainder. The bound is generous for CI scheduling noise.
        let engine = makeEngine(
            opening: { _ in
                AsyncThrowingStream { continuation in
                    Task {
                        continuation.yield(StreamDelta(role: nil, content: "Opening line."))
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continuation.finish()
                    }
                }
            },
            retrieval: {
                try await Task.sleep(nanoseconds: 350_000_000)
                return Self.chatResult()
            },
            grounded: { _ in Self.stream(["Grounded."]) }
        )
        let summary = try await engine.run { _ in }
        let wait = try XCTUnwrap(summary.retrievalWaitMs)
        XCTAssertLessThan(wait, 200)
        XCTAssertNotNil(summary.chatResult)
    }

    func testGroundedPromptCarriesContextSeamAndPrefill() async throws {
        let promptBox = LockedValue<UserInput.Prompt?>(nil)
        let engine = makeEngine(
            opening: { _ in Self.stream(["The opening."]) },
            retrieval: { Self.chatResult(context: "PERSONAL CONTEXT") },
            grounded: { prompt in
                promptBox.withLock { $0 = prompt }
                return Self.stream(["done."])
            }
        )
        _ = try await engine.run { _ in }

        let sent = messages(from: try XCTUnwrap(promptBox.withLock { $0 }))
        XCTAssertTrue(sent.contains { $0["content"] == "PERSONAL CONTEXT" })
        XCTAssertTrue(sent.contains { $0["content"] == RealtimeTurnEngine.seamInstruction })
        // Prefill: the final message is the assistant opening.
        XCTAssertEqual(sent.last?["role"], "assistant")
        XCTAssertEqual(sent.last?["content"], "The opening.")
    }

    func testRetrievalFailureDegradesGroundedPass() async throws {
        let promptBox = LockedValue<UserInput.Prompt?>(nil)
        let engine = makeEngine(
            opening: { _ in Self.stream(["Opening still spoke."]) },
            retrieval: { throw TestError() },
            grounded: { prompt in
                promptBox.withLock { $0 = prompt }
                return Self.stream(["Fallback answer."])
            }
        )
        let summary = try await engine.run { _ in }

        XCTAssertNil(summary.chatResult)
        let sent = messages(from: try XCTUnwrap(promptBox.withLock { $0 }))
        XCTAssertTrue(sent.contains { $0["content"] == RealtimeTurnEngine.degradedInstruction })
        XCTAssertEqual(sent.last?["content"], "Opening still spoke.")
        XCTAssertEqual(summary.accumulatedText, "Opening still spoke.Fallback answer.")
    }

    func testOpeningFailureFallsBackToGroundedOnly() async throws {
        let log = FrameLog()
        let promptBox = LockedValue<UserInput.Prompt?>(nil)
        let engine = makeEngine(
            opening: { _ in Self.stream([], thenFail: true) },
            retrieval: { Self.chatResult() },
            grounded: { prompt in
                promptBox.withLock { $0 = prompt }
                return Self.stream(["Grounded only."])
            }
        )
        let summary = try await engine.run { log.append($0) }

        XCTAssertEqual(summary.openingText, "")
        XCTAssertEqual(summary.accumulatedText, "Grounded only.")
        let sent = messages(from: try XCTUnwrap(promptBox.withLock { $0 }))
        // No prefill, no seam — the grounded pass IS the whole reply.
        XCTAssertFalse(sent.contains { $0["content"] == RealtimeTurnEngine.seamInstruction })
        XCTAssertFalse(sent.contains { $0["role"] == "assistant" })
    }

    func testTTSFailureEmitsFrameAndTextContinues() async throws {
        let log = FrameLog()
        let engine = makeEngine(
            opening: { _ in Self.stream(["One two. "]) },
            retrieval: { Self.chatResult() },
            grounded: { _ in Self.stream(["Three four. Five six. And the rest of it."]) },
            tts: { _ in throw TestError() }
        )
        let summary = try await engine.run { log.append($0) }

        XCTAssertTrue(summary.ttsFailed)
        XCTAssertEqual(log.signature.filter { $0 == "tts.failed" }.count, 1)
        XCTAssertEqual(log.signature.filter { $0 == "pcm" }.count, 0)
        XCTAssertEqual(summary.accumulatedText,
                       "One two. Three four. Five six. And the rest of it.")
    }

    func testGroundedMarkersAreStrippedFromTokensButKeptRaw() async throws {
        let log = FrameLog()
        let engine = makeEngine(
            opening: { _ in Self.stream(["Opening. "]) },
            retrieval: { Self.chatResult() },
            grounded: { _ in Self.stream(["Cited fact.", "[[1]]", " Plain tail."]) }
        )
        let summary = try await engine.run { log.append($0) }

        XCTAssertEqual(log.tokens(phase: .grounded), "Cited fact. Plain tail.")
        XCTAssertEqual(summary.groundedRaw, "Cited fact.[[1]] Plain tail.")
        XCTAssertEqual(summary.accumulatedText, "Opening. Cited fact. Plain tail.")
    }

    func testSendFailureAbortsTheTurn() async throws {
        let engine = makeEngine(
            opening: { _ in Self.stream(["A sentence. Another one. And more. Keeps going."]) },
            retrieval: { Self.chatResult() },
            grounded: { _ in Self.stream(["Never reached?"]) }
        )
        struct ClientGone: Error {}
        do {
            _ = try await engine.run { frame in
                if case .token = frame { throw ClientGone() }
            }
            XCTFail("expected throw")
        } catch {
            // ClientGone or CancellationError depending on which child surfaced
            // first — either way the run terminated instead of completing.
        }
    }
}

// MARK: - Verbatim compact (re-landed fast path)

final class CompactVerbatimTests: XCTestCase {

    func testSmallRetrievalInjectsVerbatim() async throws {
        let seer = Seer()
        let partitions = [
            Seer.Partition.test(documentId: "doc-a", text: "Alpha fact lives here.", ownerId: "owner-1"),
            Seer.Partition.test(documentId: "doc-b", text: "Beta fact lives here.", ownerId: "owner-1"),
        ]
        let result = try await seer.compact(
            messages: [],
            partitions: partitions,
            modelProvider: ModelProvider(logger: Logger(label: "compact-tests")),
            request: .test(ownerId: "owner-1")
        )

        XCTAssertTrue(result.usedVerbatim)
        XCTAssertTrue(result.citations.isEmpty)
        XCTAssertEqual(result.sourceIndex[1], "doc-a")
        XCTAssertEqual(result.sourceIndex[2], "doc-b")
        XCTAssertTrue(result.text.contains("[1]"))
        XCTAssertTrue(result.text.contains("Alpha fact lives here."))
        XCTAssertTrue(result.text.contains("[2]"))
        XCTAssertTrue(result.text.contains("Beta fact lives here."))
        // The verbatim block carries no conversation-history section — history
        // rides as real message turns instead.
        XCTAssertFalse(result.text.contains("Message History"))
    }

    func testThresholdCountsPartitionCharacters() {
        // Just under vs. just over the boundary, by construction.
        let under = String(repeating: "a", count: Seer.verbatimContextThreshold)
        let over = under + "a"
        XCTAssertLessThanOrEqual(under.count, Seer.verbatimContextThreshold)
        XCTAssertGreaterThan(over.count, Seer.verbatimContextThreshold)
    }
}

// MARK: - Bonnie-client support framing

final class BonnieClientFramingTests: XCTestCase {

    func testBonnieToolPartitionsGetTheirOwnVerbatimTier() async throws {
        let seer = Seer()
        let partitions = [
            Seer.Partition.test(documentId: "doc-a", text: "Chapter notes live here.", ownerId: "owner-1"),
            Seer.Partition.test(documentId: "bonnie-tool-123", text: "replace_symbol — for: add pink\nEdited Paper.swift", ownerId: "owner-1"),
        ]
        let result = try await seer.compact(
            messages: [],
            partitions: partitions,
            modelProvider: ModelProvider(logger: Logger(label: "framing-tests")),
            request: .test(ownerId: "owner-1"),
            bonnieClient: true
        )
        XCTAssertTrue(result.usedVerbatim)
        // The tool deposit rides its own tier, not "the user's documents".
        XCTAssertTrue(result.text.contains("Bonnie's Past Actions"))
        let documentsSection = result.text
            .components(separatedBy: "**Documents:**")[1]
            .components(separatedBy: "**")[0]
        XCTAssertTrue(documentsSection.contains("Chapter notes live here."))
        XCTAssertFalse(documentsSection.contains("Edited Paper.swift"))
        // Both keep their [n] tags for the citation protocol.
        XCTAssertEqual(result.sourceIndex[2], "bonnie-tool-123")
    }

    func testClassicClientKeepsToolDepositsInDocuments() async throws {
        let seer = Seer()
        let partitions = [
            Seer.Partition.test(documentId: "bonnie-tool-123", text: "tool output text", ownerId: "owner-1"),
        ]
        let result = try await seer.compact(
            messages: [],
            partitions: partitions,
            modelProvider: ModelProvider(logger: Logger(label: "framing-tests")),
            request: .test(ownerId: "owner-1")
        )
        XCTAssertFalse(result.text.contains("Bonnie's Past Actions"))
        XCTAssertTrue(result.text.contains("tool output text"))
    }

    func testContextUsageGuideFraming() {
        let bonnie = Seer.contextUsageGuide(bonnieClient: true, citationProtocol: "CITE-RULES")
        XCTAssertTrue(bonnie.contains("BACKGROUND SUPPORT"))
        XCTAssertTrue(bonnie.contains("never recite it as your answer"))
        XCTAssertTrue(bonnie.contains("Bonnie's Past Actions"))
        XCTAssertTrue(bonnie.contains("never the subject of the reply"))
        XCTAssertTrue(bonnie.contains("CITE-RULES"))

        let classic = Seer.contextUsageGuide(bonnieClient: false, citationProtocol: "CITE-RULES")
        XCTAssertFalse(classic.contains("BACKGROUND SUPPORT"))
        XCTAssertFalse(classic.contains("Bonnie's Past Actions"))
        XCTAssertTrue(classic.contains("the user's own notes and files"))
        XCTAssertTrue(classic.contains("CITE-RULES"))
    }

    func testMemoryInstructionFraming() {
        let empty = Seer.memoryInstruction(contextEmpty: true, bonnieClient: true)
        XCTAssertTrue(empty.contains("no retrieved memories"))

        let bonnie = Seer.memoryInstruction(contextEmpty: false, bonnieClient: true)
        XCTAssertTrue(bonnie.contains("background support"))
        XCTAssertTrue(bonnie.contains("CURRENT request"))
        XCTAssertTrue(bonnie.contains("never let them redirect the task"))

        let classic = Seer.memoryInstruction(contextEmpty: false, bonnieClient: false)
        XCTAssertTrue(classic.contains("draw on them specifically and directly"))
        XCTAssertFalse(classic.contains("background support"))
    }

    func testClientFlagDecodesOnChatRequest() throws {
        let json = #"{"messages": [], "seer": {"owner_id": "abc"}, "client": "bonnie"}"#
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.client, "bonnie")

        let plain = #"{"messages": [], "seer": {"owner_id": "abc"}}"#
        let request2 = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(plain.utf8))
        XCTAssertNil(request2.client)
    }
}
