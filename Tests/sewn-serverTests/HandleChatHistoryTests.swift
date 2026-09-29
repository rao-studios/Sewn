//
//  HandleChatHistoryTests.swift
//  sewn-serverTests
//
//  The conversation `handleChat` hands the model: everything before the message being
//  answered. A repeated question used to drop the FIRST time it was asked too (history was
//  deduplicated by content), so the history opened on the assistant's reply — which the
//  on-device model then copied.
//

import Foundation
import XCTest
@testable import sewn_server

final class HandleChatHistoryTests: XCTestCase {

    private func messages(_ pairs: [(String, String)]) throws -> [ChatMessageRequestData] {
        let json = "[" + pairs.map { #"{"role":"\#($0.0)","content":"\#($0.1)"}"# }.joined(separator: ",") + "]"
        return try JSONDecoder().decode([ChatMessageRequestData].self, from: Data(json.utf8))
    }

    private func roles(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { $0[MessageProcessingKeys.role] as? String }
    }

    private func texts(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { $0[MessageProcessingKeys.content] as? String }
    }

    func testARepeatedQuestionKeepsItsFirstAsking() throws {
        let history = Sewn.historyEntries(try messages([
            ("user", "How are you doing?"),
            ("assistant", "Good morning!"),
            ("user", "What's the capital of France?"),
            ("assistant", "Paris."),
            ("user", "How are you doing?"),
        ]))
        XCTAssertEqual(roles(history), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(texts(history).first, "How are you doing?")
    }

    func testOnlyTheMessageBeingAnsweredIsLeftOut() throws {
        let history = Sewn.historyEntries(try messages([("user", "Hi"), ("assistant", "Hello."), ("user", "What's new?")]))
        XCTAssertEqual(texts(history), ["Hi", "Hello."])
    }

    func testADuplicatedSubmissionIsDroppedOnce() throws {
        let history = Sewn.historyEntries(try messages([("assistant", "Hello."), ("user", "Ping"), ("user", "Ping")]))
        XCTAssertEqual(texts(history), ["Hello."])
    }

    func testNoUserMessageMeansNoHistory() throws {
        XCTAssertTrue(Sewn.historyEntries(try messages([("assistant", "Hello.")])).isEmpty)
    }

    // MARK: - Which history reaches the model

    private var twelveTurns: [[String: Any]] {
        (0..<12).map { [MessageProcessingKeys.role: $0 % 2 == 0 ? "user" : "assistant",
                        MessageProcessingKeys.content: "turn \($0)"] }
    }

    func testAnOnDeviceTurnWithNothingRetrievedKeepsItsHistory() {
        let turns = Sewn.historyTurns(twelveTurns, usedVerbatimContext: false, contextEmpty: true, provider: .local)
        XCTAssertEqual(texts(turns), (2..<12).map { "turn \($0)" })
    }

    /// Hosted is unchanged: with nothing retrieved it still sends no history.
    func testAHostedTurnWithNothingRetrievedStillSendsNone() {
        for provider in [LLMProvider.mistral, .tinker] {
            XCTAssertTrue(Sewn.historyTurns(twelveTurns, usedVerbatimContext: false, contextEmpty: true, provider: provider).isEmpty)
        }
    }

    func testVerbatimContextSendsHistoryForEveryProvider() {
        for provider in [LLMProvider.mistral, .tinker, .local] {
            XCTAssertEqual(Sewn.historyTurns(twelveTurns, usedVerbatimContext: true, contextEmpty: false, provider: provider).count, 10)
        }
    }

    /// A briefing already carries the conversation inside its compacted text.
    func testABriefingSendsNoTurnsOnDeviceEither() {
        XCTAssertTrue(Sewn.historyTurns(twelveTurns, usedVerbatimContext: false, contextEmpty: false, provider: .local).isEmpty)
    }
}
