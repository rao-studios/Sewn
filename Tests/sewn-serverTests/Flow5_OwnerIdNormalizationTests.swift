//
//  Flow5_OwnerIdNormalizationTests.swift
//  sewn-serverTests
//
//  Tests for ownerId case-normalization introduced to fix split royalty distributions
//  caused by the same UUID appearing in mixed-case forms (e.g. "0455d67e-..." vs
//  "0455D67E-..."). The fix normalizes ownerId to lowercase at Sewn.Partition
//  construction time — both via the memberwise init and via Decodable — so all
//  downstream grouping (addBatch byOwner dict, Gita royalty dict) treats them as
//  identical.
//
//  Sections
//    1. Sewn.Partition — ownerId is always lowercase at init and decode time
//    2. Gita.royalty — mixed-case ownerIds produce a single contribution entry
//

import XCTest
@testable import sewn_server

final class Flow5_OwnerIdNormalizationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sewn-flow10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // =========================================================================
    // MARK: - Section 1: Sewn.Partition — ownerId normalization at construction
    // =========================================================================

    func testPartitionInitLowercasesOwnerId() {
        let p = Sewn.Partition.test(ownerId: "0455D67E-6B13-41CF-ACC0-4F0762C76A0B")
        XCTAssertEqual(p.ownerId, "0455d67e-6b13-41cf-acc0-4f0762c76a0b",
            "Partition init must lowercase ownerId — uppercase UUID must be folded")
    }

    func testPartitionInitAlreadyLowercaseIsUnchanged() {
        let lower = "0455d67e-6b13-41cf-acc0-4f0762c76a0b"
        let p = Sewn.Partition.test(ownerId: lower)
        XCTAssertEqual(p.ownerId, lower,
            "Partition init must leave an already-lowercase ownerId unchanged")
    }

    func testPartitionInitMixedCaseIsLowercased() {
        let p = Sewn.Partition.test(ownerId: "Alice")
        XCTAssertEqual(p.ownerId, "alice",
            "Partition init must lowercase any mixed-case ownerId")
    }

    func testPartitionDecodeLowercasesOwnerId() throws {
        // Build JSON with an uppercase owner_id and decode via Decodable.
        let json = """
        {
            "id": "p1",
            "document_id": "doc1",
            "url": "https://example.com",
            "embedding": [],
            "text": "hello",
            "owner_id": "0455D67E-6B13-41CF-ACC0-4F0762C76A0B"
        }
        """.data(using: .utf8)!

        let p = try JSONDecoder().decode(Sewn.Partition.self, from: json)
        XCTAssertEqual(p.ownerId, "0455d67e-6b13-41cf-acc0-4f0762c76a0b",
            "Decodable init must lowercase ownerId — uppercase JSON value must be folded")
    }

    func testPartitionDecodeLowerAndUpperProduceSameOwnerId() throws {
        func decode(_ ownerId: String) throws -> Sewn.Partition {
            let json = """
            {"id":"p","document_id":"d","url":"https://example.com","embedding":[],"text":"t","owner_id":"\(ownerId)"}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(Sewn.Partition.self, from: json)
        }

        let lower = try decode("abc123")
        let upper = try decode("ABC123")
        XCTAssertEqual(lower.ownerId, upper.ownerId,
            "Decoded ownerId must be identical regardless of the case in the JSON payload")
    }

    // =========================================================================
    // MARK: - Section 2: Gita.royalty — mixed-case merges into one contribution
    // =========================================================================

    private var gita: Gita { Gita(logger: .test) }

    func testRoyaltyMixedCaseOwnerIdsProduceSingleEntry() {
        // Replicate the production log: same UUID in two cases, split 65/34.
        let canonical = "0455d67e-6b13-41cf-acc0-4f0762c76a0b"
        let uppercase = "0455D67E-6B13-41CF-ACC0-4F0762C76A0B"

        let partitions = [
            Sewn.Partition.test(id: "p1", documentId: "doc1", text: "hello world foo bar", ownerId: canonical),
            Sewn.Partition.test(id: "p2", documentId: "doc2", text: "one two",             ownerId: uppercase),
        ]

        let contribution = gita.royalty(for: partitions)
        XCTAssertEqual(contribution.owners.count, 1,
            "Mixed-case variants of the same ownerId must produce exactly one Gita.Owner — " +
            "not a split 65.91% / 34.09% distribution")

        let owner = contribution.owners.first
        XCTAssertEqual(owner?.royalty ?? 0, 1.0, accuracy: 0.001,
            "The single merged owner must receive 100% of the royalty")
        XCTAssertEqual(owner?.ownerId, canonical,
            "The owner's id must be stored in normalized (lowercase) form")
    }

    func testRoyaltyAllUpperCaseOwnerIdFolded() {
        let partitions = [
            Sewn.Partition.test(id: "p1", documentId: "d1", text: "word1 word2", ownerId: "ALICE"),
            Sewn.Partition.test(id: "p2", documentId: "d2", text: "word3",       ownerId: "alice"),
        ]

        let contribution = gita.royalty(for: partitions)
        XCTAssertEqual(contribution.owners.count, 1,
            "\"ALICE\" and \"alice\" must map to the same owner — only one contribution entry")
    }

    func testRoyaltyDistinctOwnersUnaffected() {
        let partitions = [
            Sewn.Partition.test(id: "p1", documentId: "d1", text: "hello world", ownerId: "alice"),
            Sewn.Partition.test(id: "p2", documentId: "d2", text: "foo bar baz", ownerId: "bob"),
        ]

        let contribution = gita.royalty(for: partitions)
        XCTAssertEqual(contribution.owners.count, 2,
            "Two genuinely different owners must still produce two distinct contribution entries")
    }

    func testRoyaltyMixedCaseSumsToOne() {
        // Three partitions: same owner in three different case forms.
        let partitions = [
            Sewn.Partition.test(id: "p1", documentId: "d1", text: "a b c",     ownerId: "Owner-X"),
            Sewn.Partition.test(id: "p2", documentId: "d2", text: "d e",       ownerId: "OWNER-X"),
            Sewn.Partition.test(id: "p3", documentId: "d3", text: "f g h i j", ownerId: "owner-x"),
        ]

        let contribution = gita.royalty(for: partitions)
        XCTAssertEqual(contribution.owners.count, 1,
            "Three case variants of the same owner must merge into one entry")
        let total = contribution.owners.reduce(0.0) { $0 + $1.royalty }
        XCTAssertEqual(total, 1.0, accuracy: 0.001,
            "Merged royalties must still sum to 1.0")
    }
}
