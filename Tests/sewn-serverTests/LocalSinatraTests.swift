//
//  LocalSinatraTests.swift
//  sewn-serverTests
//
//  The on-device provider's SinatraMLX wiring: the `sinatra` request object, the
//  retrieved partitions handed over, sampling now honoured, the diagnostics on the wire,
//  and — gated, with a real model — two turns through LocalInference where the second
//  message labels the first.
//

import Foundation
import Logging
import XCTest
@testable import sewn_server

final class LocalSinatraWireTests: XCTestCase {

    private func chatRequest(_ extra: String = "") throws -> ChatCompletionRequest {
        let json = #"{"messages":[{"role":"user","content":"What do my notes say?"}],"provider":"local","sewn":{"owner_id":"Owner-1"}"# + extra + "}"
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
    }

    func testTheSinatraObjectDecodesAndValidates() throws {
        XCTAssertNil(try chatRequest().sinatra)
        let request = try chatRequest(#","sinatra":{"mode":"dense","trace":"full","seed":7,"record":false}"#)
        XCTAssertEqual(request.sinatra, SinatraRequestOptions(mode: "dense", trace: "full", seed: 7, record: false))
        XCTAssertNil(request.sinatra?.validationError)
        XCTAssertNotNil(try chatRequest(#","sinatra":{"mode":"loud"}"#).sinatra?.validationError)
        XCTAssertNotNil(try chatRequest(#","sinatra":{"trace":"everything"}"#).sinatra?.validationError)
    }

    func testTheTurnCarriesTheOwnerAndTheLabellingMessage() throws {
        let request = try chatRequest(#","sinatra":{"seed":3}"#)
        let at = Date(timeIntervalSince1970: 1_758_000_000)
        let turn = try XCTUnwrap(LocalTurnContext.make(owner: "Owner-1", request: request, userMessageAt: at))
        XCTAssertEqual(turn.owner, "owner-1")
        XCTAssertEqual(turn.userMessageText, "What do my notes say?")
        XCTAssertEqual(turn.userMessageAt, at)
        XCTAssertEqual(turn.options?.seed, 3)
        XCTAssertNil(LocalTurnContext.make(owner: nil, request: request, userMessageAt: at))
    }

    func testRetrievedPartitionsKeepScoresAndDropDuplicates() {
        let url = URL(string: "thread://node")!
        let partitions = [
            Sewn.Partition(id: "a", documentId: "d1", url: url, embedding: [], text: "alpha", ownerId: "o"),
            Sewn.Partition(id: "b", documentId: "d2", url: url, embedding: [], text: "beta", ownerId: "o"),
            Sewn.Partition(id: "a", documentId: "d1", url: url, embedding: [], text: "alpha", ownerId: "o"),
        ]
        let retrieved = Sewn.RetrievedPartition.from(partitions, scores: ["a": 0.2, "b": 0.7])
        XCTAssertEqual(retrieved.map(\.id), ["a", "b"])
        XCTAssertEqual(retrieved.map(\.score), [0.2, 0.7])
        XCTAssertEqual(retrieved.first?.text, "alpha")
    }

    func testTheLocalRowAloneCarriesSinatraStatus() throws {
        let status = SinatraStatusInfo(
            observations: 12, labelled: 9, trainedAt: "2026-09-23T10:00:00Z", reliability: 0.4,
            lastBiasMagnitude: 1.2, store: "/tmp/store")
        let local = providerInfo(.local, localState: .cold, localBuilt: true, sinatra: status)
        let hosted = providerInfo(.mistral, localState: .cold, localBuilt: true, sinatra: status)
        XCTAssertEqual(local.sinatra, status)
        XCTAssertNil(hosted.sinatra)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(local), encoding: .utf8))
        XCTAssertTrue(json.contains(#""trained_at":"2026-09-23T10:00:00Z""#))
        XCTAssertTrue(json.contains(#""last_bias_magnitude":1.2"#))
    }

    func testTheTrailingChunkCarriesTheDiagnostics() throws {
        let diagnostics = LocalSinatraDiagnostics(
            turnId: "t", mode: "lexical", coldStart: true, partitions: 3, weightedPartitions: 1,
            biasTokens: 40, biasMaxAbs: 1.5, gate: 0, previousReward: 0.8, previousReplyKind: "replied",
            observations: 2, labelled: 1, reliability: 0, trainedAt: nil, trainingScheduled: false,
            encodeMs: 2.5,
            trace: .init(
                traceId: "x", level: "summary", seed: 1, steps: 10, meanEntropyPre: 1, meanEntropyPost: 0.8,
                meanEntropyShift: -0.2, totalKl: 0.3, totalGain: 1.1, meanMassIntoMask: 0.05,
                divergenceRate: 0.1, firstDivergenceStep: 4, flippedArgmaxSteps: 1, sampledInMaskShare: 0.3))
        let chunk = ChatCompletionChunkResponse(id: "c", model: "m", choices: [], references: [], sinatra: diagnostics)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(chunk), encoding: .utf8))
        XCTAssertTrue(json.contains(#""sinatra":{"#))
        XCTAssertTrue(json.contains(#""previous_reward":0.8"#))
        XCTAssertTrue(json.contains(#""mean_entropy_shift":-0.2"#))
        let plain = ChatCompletionChunkResponse(id: "c", model: "m", choices: [], references: [])
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(plain), encoding: .utf8)).contains("sinatra\":{"))
    }

    /// Mistral's template rejects a history that opens on the assistant. An
    /// unprompted remark made before the user spoke moves into the system prompt.
    func testAnOpeningRemarkMovesIntoTheSystemPrompt() {
        let conversation = LocalMessageMapper.conversation(
            system: "You are Mary.",
            messages: [
                .init(role: "assistant", content: "That chart looks off by a week."),
                .init(role: "assistant", content: "The axis starts in March."),
                .init(role: "user", content: "Why is that?"),
            ],
            tools: nil)
        XCTAssertEqual(conversation.turns, [.init(isUser: true, text: "Why is that?")])
        XCTAssertTrue(conversation.system.hasPrefix("You are Mary.\n\nBefore the user's first message here, you said:\n"))
        XCTAssertTrue(conversation.system.contains("That chart looks off by a week.\n\nThe axis starts in March."))
    }

    func testAnOrdinaryHistoryIsUntouched() {
        let conversation = LocalMessageMapper.conversation(
            system: "You are Mary.",
            messages: [
                .init(role: "user", content: "Hi"),
                .init(role: "assistant", content: "Hello."),
                .init(role: "user", content: "What's new?"),
            ],
            tools: nil)
        XCTAssertEqual(conversation.system, "You are Mary.")
        XCTAssertEqual(conversation.turns.map(\.isUser), [true, false, true])
    }

    /// After the 200 is out, a failure has to say so in the stream itself.
    func testAFailedStreamSaysSoInItsOwnEvent() throws {
        let json = try XCTUnwrap(String(
            data: JSONEncoder().encode(StreamErrorEvent(ProviderUnavailable.localFailed("no metallib"))),
            encoding: .utf8))
        XCTAssertTrue(json.contains(#""error":{"#))
        XCTAssertTrue(json.contains(#""type":"generation_failed""#))
        XCTAssertTrue(json.contains("On-device model unavailable: no metallib"))
    }

    #if canImport(MLXLLM)
    func testSamplingIsHonouredOnDevice() {
        let parameters = ChatGenerationParameters(
            maxTokens: 300, temperature: 0.4, topP: 0.9, repetitionPenalty: 1.1, repetitionContextSize: 20,
            kvBits: 4, kvGroupSize: 64, quantizedKVStart: 5)
        let mapped = LocalInference.generateParameters(LocalSampling(parameters, maxTokens: 300), seed: 9)
        XCTAssertEqual(mapped.maxTokens, 300)
        XCTAssertEqual(mapped.temperature, 0.4)
        XCTAssertEqual(mapped.topP, 0.9)
        XCTAssertEqual(mapped.repetitionPenalty, 1.1)
        XCTAssertEqual(mapped.repetitionContextSize, 20)
        XCTAssertEqual(mapped.kvBits, 4)
        XCTAssertEqual(mapped.quantizedKVStart, 5)
        XCTAssertEqual(mapped.seed, 9)
        let neutral = ChatGenerationParameters(
            maxTokens: 10, temperature: 0.8, topP: 1, repetitionPenalty: 1.0, repetitionContextSize: 20,
            kvBits: nil, kvGroupSize: 64, quantizedKVStart: 0)
        XCTAssertNil(LocalInference.generateParameters(LocalSampling(neutral, maxTokens: 10)).repetitionPenalty)
    }

    func testEnvironmentOverridesTheSinatraConfiguration() {
        let configuration = LocalInference.sinatraConfiguration(environment: [
            "SEWN_SINATRA_MODE": "dense", "SEWN_SINATRA_TRACE": "full", "SEWN_SINATRA_ALPHA": "0.5",
        ])
        XCTAssertEqual(configuration.biasMode.rawValue, "dense")
        XCTAssertEqual(configuration.traceLevel.rawValue, "full")
        XCTAssertEqual(configuration.alpha, 0.5)
        XCTAssertEqual(LocalInference.sinatraConfiguration(environment: ["SEWN_SINATRA_MODE": "nope"]).biasMode.rawValue, "lexical")
    }
    #endif
}

#if canImport(MLXLLM)
/// Two real turns through LocalInference. Needs the model on disk, the metallib beside the
/// test bundle, and SEWN_LOCAL_SINATRA_TESTS=1 (SEWN_LOCAL_SINATRA_MODEL picks the model).
final class LocalSinatraLiveTests: XCTestCase {

    func testASecondMessageLabelsTheFirstTurn() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SEWN_LOCAL_SINATRA_TESTS"] == "1", "set SEWN_LOCAL_SINATRA_TESTS=1 to run with a real model")
        let model = env["SEWN_LOCAL_SINATRA_MODEL"] ?? "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit"
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("sewn-sinatra-\(UUID().uuidString)")
        let local = LocalInference(logger: Logger(label: "test"), storeDirectory: store, gpuPreflight: false)
        let retrieved = [
            Sewn.RetrievedPartition(id: "garden#0", documentId: "docs/garden", text: "The raised garden beds get morning sun, so tomatoes and basil thrive there. Compost from kitchen scraps feeds the soil every spring.", score: 0.12, createdAt: nil),
            Sewn.RetrievedPartition(id: "bread#0", documentId: "docs/bread", text: "The sourdough starter needs feeding twice a day with equal weights of flour and water.", score: 0.31, createdAt: nil),
        ]
        let parameters = ChatGenerationParameters(
            maxTokens: 60, temperature: 0, topP: 1, repetitionPenalty: 1.0, repetitionContextSize: 20,
            kvBits: nil, kvGroupSize: 64, quantizedKVStart: 0)
        let sampling = LocalSampling(parameters, maxTokens: 60)
        let system = "Answer from the notes in one sentence."

        func turn(_ text: String, history: [Requests.Chat.Get.Message]) async throws -> (String, LocalSinatraDiagnostics?) {
            let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(
                #"{"messages":[{"role":"user","content":"\#(text)"}],"provider":"local","sewn":{"owner_id":"live-owner"},"sinatra":{"trace":"summary","seed":1}}"#.utf8))
            let context = try XCTUnwrap(LocalTurnContext.make(owner: "live-owner", request: request, userMessageAt: Date()))
            let result = try await local.generate(
                system: system, messages: history + [.init(role: "user", content: text)], tools: nil,
                modelID: model, sampling: sampling, retrieved: retrieved, turn: context)
            return (result.text, result.sinatra)
        }

        let (first, firstDiagnostics) = try await turn("What should I do in the garden?", history: [])
        XCTAssertFalse(first.isEmpty)
        let one = try XCTUnwrap(firstDiagnostics)
        XCTAssertEqual(one.partitions, 2)
        XCTAssertNil(one.previousReward)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let (second, secondDiagnostics) = try await turn(
            "Great, tell me more about the garden beds compost and tomatoes",
            history: [.init(role: "user", content: "What should I do in the garden?"), .init(role: "assistant", content: first)])
        XCTAssertFalse(second.isEmpty)
        let two = try XCTUnwrap(secondDiagnostics)
        XCTAssertNotNil(two.previousReward, "the second message should label the first turn")
        XCTAssertEqual(two.labelled, 1)
        let status = await local.sinatraStatus(owner: "live-owner")
        XCTAssertEqual(status?.observations, 2)
        await local.flush()
        print("[live] first: \(first)\n[live] second: \(second)\n[live] R(first) = \(two.previousReward ?? -1), bias tokens \(two.biasTokens), trace \(two.trace.map { "ΔH \($0.meanEntropyShift) gain \($0.totalGain)" } ?? "none")")
    }
}
#endif
