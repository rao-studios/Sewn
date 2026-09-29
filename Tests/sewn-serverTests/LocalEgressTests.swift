//
//  LocalEgressTests.swift
//  sewn-serverTests
//
//  An on-device turn never reaches a hosted LLM vendor:
//  - Sinatra.prepare makes no request for a local turn (it used to send the
//    user's message and the reply to Mistral for resonance)
//  - a hosted turn still makes its one resonance request, unchanged
//  - VendorEgress refuses vendors (not Supabase) in the task and its children
//

import Foundation
import Logging
import XCTest
@testable import sewn_server

final class LocalEgressTests: XCTestCase {

    private var savedKey: String?

    override func setUp() {
        super.setUp()
        savedKey = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"]
        // A key present is the dangerous case: without one nothing could leak.
        setenv("MISTRAL_API_KEY", "test-key", 1)
        RecordingURLProtocol.reset()
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        if let savedKey {
            setenv("MISTRAL_API_KEY", savedKey, 1)
        } else {
            unsetenv("MISTRAL_API_KEY")
        }
        super.tearDown()
    }

    private func turn(_ user: String) -> [ChatMessageRequestData] {
        [
            ChatMessageRequestData(role: .assistant, content: .text("Pasta would be lovely tonight, with garlic and lemon."), timestamp: nil),
            ChatMessageRequestData(role: .user, content: .text(user), timestamp: nil),
        ]
    }

    // MARK: - Sinatra.prepare

    func testLocalTurnSendsNothingToAVendor() async throws {
        let result = try await Sinatra(logger: .test).prepare(
            turn("I love the garlic and lemon idea"),
            request: .test(ownerId: "local-ambient"),
            modelProvider: ModelProvider(logger: .test),
            provider: .local)

        XCTAssertEqual(RecordingURLProtocol.hosts, [])
        XCTAssertNil(result.resonancePartition)
    }

    func testHostedTurnStillMakesItsResonanceRequest() async {
        do {
            _ = try await Sinatra(logger: .test).prepare(
                turn("I love the garlic and lemon idea"),
                request: .test(),
                modelProvider: ModelProvider(logger: .test),
                provider: .mistral)
            XCTFail("the recorder fails every request, so prepare must throw")
        } catch {}

        XCTAssertEqual(RecordingURLProtocol.hosts, ["api.mistral.ai"])
    }

    // MARK: - VendorEgress

    func testRefusalCoversVendorsAndTheTasksATurnSpawns() async throws {
        try await VendorEgress.refusing(when: true) {
            XCTAssertThrowsError(try VendorEgress.check(.mistral))
            XCTAssertThrowsError(try VendorEgress.check(.tinker))
            XCTAssertThrowsError(try VendorEgress.check(URL(string: "https://api.mistral.ai/v1/chat/completions")))
            XCTAssertNoThrow(try VendorEgress.check(.supabase))
            XCTAssertNoThrow(try VendorEgress.check(URL(string: "http://127.0.0.1:47081/v1/put")))

            // Sinatra and auto-memory run in unstructured Tasks spawned by the turn.
            let spawned = Task { try VendorEgress.check(.mistral) }
            do {
                try await spawned.value
                XCTFail("a Task spawned inside the turn must inherit the refusal")
            } catch let error as ProviderUnavailable {
                XCTAssertEqual(error, .egressRefused(host: "api.mistral.ai", reason: "on-device turn"))
            }
        }
    }

    func testNoRefusalOutsideALocalTurn() async throws {
        XCTAssertNoThrow(try VendorEgress.check(.mistral))
        try await VendorEgress.refusing(when: false) {
            XCTAssertNoThrow(try VendorEgress.check(.mistral))
        }
    }

    func testNetworkServiceRefusesBeforeDialling() async {
        await VendorEgress.refusing(when: true) {
            do {
                _ = try await ModelProvider(logger: .test).run(
                    "hello", maxTokens: 4, provider: .mistral, logger: .test)
                XCTFail("a vendor call inside a local turn must throw")
            } catch {
                XCTAssertEqual(error as? ProviderUnavailable,
                               .egressRefused(host: "api.mistral.ai", reason: "on-device turn"))
            }
        }
        XCTAssertEqual(RecordingURLProtocol.hosts, [])
    }
}

/// Records every request's host and fails it, so nothing leaves the test.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []

    static var hosts: [String] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request.url?.host ?? "?") }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
