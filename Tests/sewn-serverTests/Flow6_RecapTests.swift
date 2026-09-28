//
//  Flow6_RecapTests.swift
//  sewn-serverTests
//
//  The running recap (Sewn+Recap):
//    - The prompt block: newest first, the token budget, ages, the newest always shown
//    - The ledger document: encode/parse round trip, a split text read as one entry
//    - Ids: per owner and app, and retrieval dropping them without losing a slot
//    - The cache: hydration merges, a forget outlives anything in flight
//    - The prompt: the recap in both the full and bare prompts, and an empty one
//      leaving today's prompt byte-identical
//    - The wire: `recap` and `recap_reset` decode, absent by default; a reset
//      keeps the recap out of the realtime opener
//

import Conduit
import Foundation
import RaoStack
import XCTest
@testable import sewn_server

final class Flow6_RecapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ minutesAgo: Double, _ text: String) -> Sewn.RecapEntry {
        Sewn.RecapEntry(at: now.addingTimeInterval(-minutesAgo * 60), text: text)
    }

    // MARK: - The prompt block

    func testSectionIsNilWithNothingToShow() {
        XCTAssertNil(Sewn.recapSection([], now: now, maxTokens: 600))
    }

    func testSectionListsNewestFirstWithAges() throws {
        let section = try XCTUnwrap(Sewn.recapSection(
            [entry(180, "The user planned the garden."), entry(20, "You compared two tents.")],
            now: now, maxTokens: 600))
        XCTAssertTrue(section.hasPrefix(Sewn.recapHeader))
        XCTAssertTrue(section.hasSuffix("---"))
        let tents = try XCTUnwrap(section.range(of: "- (20 minutes ago) You compared two tents."))
        let garden = try XCTUnwrap(section.range(of: "- (3 hours ago) The user planned the garden."))
        XCTAssertLessThan(tents.lowerBound, garden.lowerBound)
    }

    func testSectionStopsAtTheBudgetWithWholeEntries() throws {
        let long = String(repeating: "word ", count: 40)   // ~200 bytes a line
        let entries = (0..<10).map { entry(Double($0 * 10), "\($0) \(long)") }
        let section = try XCTUnwrap(Sewn.recapSection(entries, now: now, maxTokens: 120))  // 480 bytes
        let lines = section.components(separatedBy: "\n").filter { $0.hasPrefix("- (") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(") 0 word"))
        XCTAssertTrue(lines[1].contains(") 1 word"))
        XCTAssertFalse(lines.contains { $0.hasSuffix("…") })
    }

    func testTheNewestAlwaysShowsCutShort() throws {
        let section = try XCTUnwrap(Sewn.recapSection(
            [entry(1, String(repeating: "a", count: 1000))], now: now, maxTokens: 10))
        let line = try XCTUnwrap(section.components(separatedBy: "\n").first { $0.hasPrefix("- (") })
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertLessThanOrEqual(line.utf8.count, 40 + "…".utf8.count)
    }

    func testAgesReadLikeAPerson() {
        func age(_ seconds: Double) -> String {
            Sewn.recapAge(of: now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(age(10), "just now")
        XCTAssertEqual(age(60), "a minute ago")
        XCTAssertEqual(age(45 * 60), "45 minutes ago")
        XCTAssertEqual(age(60 * 60), "an hour ago")
        XCTAssertEqual(age(5 * 3600), "5 hours ago")
        XCTAssertEqual(age(30 * 3600), "yesterday")
        XCTAssertEqual(age(4 * 86400), "4 days ago")
        XCTAssertEqual(Sewn.recapAge(of: now.addingTimeInterval(60), now: now), "just now",
                       "a clock that ran ahead is never a negative age")
    }

    // MARK: - The ledger document

    func testLedgerRoundTripsNewestFirst() {
        let entries = [entry(90, "Older."), entry(5, "Newer.")]
        let texts = Sewn.encodeLedger(entries)
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts[0].hasSuffix("] Newer."))
        let parsed = Sewn.parseLedger(texts)
        XCTAssertEqual(parsed.map(\.text), ["Newer.", "Older."])
        XCTAssertEqual(parsed.map { Int($0.at.timeIntervalSince1970) },
                       [entries[1], entries[0]].map { Int($0.at.timeIntervalSince1970) })
    }

    func testLedgerFlattensNewlinesInAnEntry() {
        let texts = Sewn.encodeLedger([entry(1, "One.\n\nTwo.")])
        XCTAssertEqual(texts.count, 1)
        XCTAssertFalse(texts[0].contains("\n"))
        XCTAssertEqual(Sewn.parseLedger(texts).first?.text, "One. Two.")
    }

    func testASplitTextStillReadsAsOneEntry() {
        let texts = Sewn.encodeLedger([entry(1, "The user asked about tents.")])
        let split = [String(texts[0].prefix(35)), String(texts[0].dropFirst(35))]
        let parsed = Sewn.parseLedger(split)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].text.hasPrefix("The user"))
    }

    func testParseSkipsTextWithNoDateAhead() {
        XCTAssertEqual(Sewn.parseLedger(["stray words", ""]), [])
    }

    func testFallbackDropsTheTitle() {
        let summary = "**Tent Shopping**\n\nThe user compared two **tents**.\nThey chose the lighter one."
        XCTAssertEqual(Sewn.recapFallback(from: summary),
                       "The user compared two tents. They chose the lighter one.")
        XCTAssertEqual(Sewn.recapFallback(from: String(repeating: "x", count: 900)).count, 400)
    }

    // MARK: - Ids and retrieval

    func testLedgerIdIsPerOwnerAndApp() {
        XCTAssertEqual(Sewn.recapDocumentId(ownerId: "ABC", app: .ambient), "chat-recap-ambient-abc")
        XCTAssertEqual(Sewn.recapDocumentId(ownerId: "abc", app: nil), "chat-recap-abc")
        XCTAssertNotEqual(Sewn.recapDocumentId(ownerId: "abc", app: .ambient),
                          Sewn.recapDocumentId(ownerId: "abc", app: .veil))
        XCTAssertTrue(Sewn.recapDocumentId(ownerId: "abc", app: .craft).hasPrefix(Sewn.recapDocumentPrefix))
    }

    private func result(_ doc: String, thread: String, score: Float) -> Thread_V1_ThreadPartitionResult {
        var r = Thread_V1_ThreadPartitionResult()
        r.documentID = doc
        r.partitionID = "\(doc)-p"
        r.threadID = thread
        r.score = score
        return r
    }

    func testRetrievalDropsTheLedgerWithoutLosingASlot() {
        let results = [
            result("chat-recap-ambient-o1", thread: "A", score: 0.1),
            result("d1", thread: "A", score: 0.2),
            result("d2", thread: "A", score: 0.3),
            result("d3", thread: "A", score: 0.4),
            result("e1", thread: "B", score: 0.5),
        ]
        let kept = Sewn.droppingRecaps(results, topK: 3)
        XCTAssertEqual(kept.map(\.documentID), ["d1", "d2", "d3", "e1"])
    }

    func testRetrievalKeepsEachNodeToTopKWhenNoLedgerMatched() {
        let results = (1...4).map { result("d\($0)", thread: "A", score: Float($0)) }
        XCTAssertEqual(Sewn.droppingRecaps(results, topK: 3).map(\.documentID), ["d1", "d2", "d3"])
    }

    // MARK: - The cache

    func testAnUnreadKeyHasNoEntriesUntilHydrated() {
        let store = Sewn.RecapStore()
        let key = Sewn.RecapKey(ownerId: "o1", app: .ambient)
        XCTAssertNil(store.entries(for: key))
        let (begin, epoch) = store.beginHydration(key)
        XCTAssertTrue(begin)
        XCTAssertFalse(store.beginHydration(key).begin, "one read at a time")
        store.finishHydration(key, epoch: epoch, fetched: [entry(5, "From Thread.")])
        XCTAssertEqual(store.entries(for: key)?.map(\.text), ["From Thread."])
        XCTAssertFalse(store.beginHydration(key).begin, "read once")
    }

    func testAFailedReadIsTriedAgain() {
        let store = Sewn.RecapStore()
        let key = Sewn.RecapKey(ownerId: "o1", app: .ambient)
        let (_, epoch) = store.beginHydration(key)
        store.finishHydration(key, epoch: epoch, fetched: nil)
        XCTAssertNil(store.entries(for: key))
        XCTAssertTrue(store.beginHydration(key).begin)
    }

    func testAnEntryWrittenBeforeTheReadIsMergedWithIt() {
        let store = Sewn.RecapStore()
        let key = Sewn.RecapKey(ownerId: "o1", app: .ambient)
        let epoch = store.epoch(for: key)
        XCTAssertTrue(store.prepend(entry(1, "New here."), to: key, ifEpoch: epoch))
        XCTAssertNil(store.entries(for: key))
        store.finishHydration(key, epoch: epoch, fetched: [entry(60, "From Thread."), entry(1, "New here.")])
        XCTAssertEqual(store.entries(for: key)?.map(\.text), ["New here.", "From Thread."])
    }

    func testTheLedgerKeepsItsLimit() {
        let store = Sewn.RecapStore()
        let key = Sewn.RecapKey(ownerId: "o1", app: nil)
        store.clear(key)
        let epoch = store.epoch(for: key)
        for i in 0..<(Sewn.recapLedgerLimit + 5) {
            store.prepend(entry(Double(100 - i), "\(i)"), to: key, ifEpoch: epoch)
        }
        let kept = store.entries(for: key) ?? []
        XCTAssertEqual(kept.count, Sewn.recapLedgerLimit)
        XCTAssertEqual(kept.first?.text, "\(Sewn.recapLedgerLimit + 4)")
    }

    func testAForgetOutlivesAReadAndARecapInFlight() {
        let store = Sewn.RecapStore()
        let key = Sewn.RecapKey(ownerId: "o1", app: .ambient)
        let (_, readEpoch) = store.beginHydration(key)
        let recapEpoch = store.epoch(for: key)
        store.clear(key)
        store.finishHydration(key, epoch: readEpoch, fetched: [entry(5, "Forgotten.")])
        XCTAssertFalse(store.prepend(entry(1, "Also forgotten."), to: key, ifEpoch: recapEpoch))
        XCTAssertEqual(store.entries(for: key), [])
    }

    func testKeysAreCaseInsensitiveOnTheOwner() {
        XCTAssertEqual(Sewn.RecapKey(ownerId: "ABC", app: .ambient), Sewn.RecapKey(ownerId: "abc", app: .ambient))
    }

    func testTheBriefWaitGivesUpOnASlowRead() async {
        let slow = Task<Void, Never> { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        let start = Date()
        await Sewn.waitBriefly(for: slow, ns: 50_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertFalse(slow.isCancelled, "the read carries on to fill the cache")
        slow.cancel()
    }

    func testTheBriefWaitReturnsWithAFastRead() async {
        let fast = Task<Void, Never> {}
        let start = Date()
        await Sewn.waitBriefly(for: fast, ns: 5_000_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - The prompt

    func testAnEmptyRecapLeavesThePromptAsItWas() {
        let with = Sewn.systemPrompts(personaSection: "P", instructions: "I", recap: "", context: "C")
        let without = Sewn.systemPrompts(personaSection: "P", instructions: "I", context: "C")
        XCTAssertEqual(with.full, without.full)
        XCTAssertEqual(with.bare, without.bare)
    }

    func testTheRecapSitsBeforeTheContextInBothPrompts() throws {
        let prompts = Sewn.systemPrompts(personaSection: "P", instructions: "I", recap: "R", context: "C")
        XCTAssertEqual(prompts.full, "P\n\nI\n\nR\n\nC")
        XCTAssertEqual(prompts.bare, "P\n\nI\n\nR")
        XCTAssertTrue(prompts.full.hasPrefix(try XCTUnwrap(prompts.bare)))
        XCTAssertNil(Sewn.systemPrompts(personaSection: "P", instructions: "I", recap: "R", context: "").bare)
        XCTAssertEqual(Sewn.systemPrompts(personaSection: "P", instructions: "I", recap: "R", context: "").full,
                       "P\n\nI\n\nR\n\n")
    }

    func testTheEmptyContextPostureMakesRoomForTheRecap() {
        let plain = Sewn.memoryInstruction(contextEmpty: true, bonnieClient: false)
        XCTAssertEqual(plain, Sewn.memoryInstruction(contextEmpty: true, bonnieClient: false, hasRecap: false))
        let withRecap = Sewn.memoryInstruction(contextEmpty: true, bonnieClient: false, hasRecap: true)
        XCTAssertTrue(withRecap.contains("EARLIER IN THIS CONVERSATION"))
        XCTAssertTrue(Sewn.recapHeader.contains("EARLIER IN THIS CONVERSATION"))
        XCTAssertEqual(Sewn.memoryInstruction(contextEmpty: false, bonnieClient: false, hasRecap: true),
                       Sewn.memoryInstruction(contextEmpty: false, bonnieClient: false))
    }

    func testTheOpenerCarriesTheRecapWhenGiven() {
        XCTAssertEqual(realtimeOpeningSystemPrompt(), realtimeOpeningSystemPrompt(recap: nil))
        let prompt = realtimeOpeningSystemPrompt(recap: "--- EARLIER IN THIS CONVERSATION ---\n- (now) X\n---")
        XCTAssertTrue(prompt.hasPrefix("Your name is Sewn."))
        XCTAssertTrue(prompt.contains("- (now) X"))
        XCTAssertTrue(prompt.contains("You act through your tools"))
    }

    // MARK: - The wire

    func testRecapDecodesAndIsAbsentByDefault() throws {
        func decode(_ extra: String) throws -> ChatCompletionRequest {
            let json = """
            {"messages": [{"role": "user", "content": "hi"}], "sewn": {"owner_id": "o1"}\(extra)}
            """
            return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        }
        XCTAssertNil(try decode("").recap)
        XCTAssertNil(try decode("").recapReset)
        XCTAssertEqual(try decode(#", "recap": true"#).recap, true)
        XCTAssertEqual(try decode(#", "recap_reset": true"#).recapReset, true)
    }

    func testATurnThatForgetsTheRecapDoesNotOpenWithIt() throws {
        func decode(_ extra: String) throws -> ChatCompletionRequest {
            let json = """
            {"messages": [{"role": "user", "content": "hi"}], "sewn": {"owner_id": "o1"}\(extra)}
            """
            return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        }
        XCTAssertFalse(try decode("").opensWithRecap)
        XCTAssertTrue(try decode(#", "recap": true"#).opensWithRecap)
        XCTAssertFalse(try decode(#", "recap": true, "recap_reset": true"#).opensWithRecap)
    }
}
