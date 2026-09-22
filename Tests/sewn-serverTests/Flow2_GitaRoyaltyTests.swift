//
//  Flow2_GitaRoyaltyTests.swift
//  sewn-serverTests
//
//  Tests for Gita royalty calculation:
//  - Proportional word-count-based royalty splits
//  - Multi-owner scenarios
//  - Determinism and edge cases
//

import XCTest
@testable import sewn_server

final class Flow2_GitaRoyaltyTests: XCTestCase {

    private var gita: Gita!

    override func setUp() {
        super.setUp()
        gita = Gita(logger: .test)
    }

    private func makePartition(
        id: String,
        documentId: String,
        ownerId: String,
        text: String
    ) -> Sewn.Partition {
        Sewn.Partition.test(id: id, documentId: documentId, text: text, ownerId: ownerId)
    }

    // MARK: - Edge cases

    func testEmptyPartitionsReturnsEmptyContribution() {
        let contribution = gita.royalty(for: [])
        XCTAssertTrue(contribution.owners.isEmpty)
    }

    // MARK: - Single owner

    func testSingleOwnerReceivesFullRoyalty() {
        let partitions = [
            makePartition(id: "p1", documentId: "doc1", ownerId: "alice", text: "hello world foo bar"),
            makePartition(id: "p2", documentId: "doc1", ownerId: "alice", text: "more text"),
        ]
        let contribution = gita.royalty(for: partitions)

        XCTAssertEqual(contribution.owners.count, 1)
        let owner = contribution.owners.first!
        XCTAssertEqual(owner.ownerId, "alice")
        XCTAssertEqual(owner.royalty, 1.0, accuracy: 0.001)
    }

    // MARK: - Multi-owner proportional split

    func testTwoOwnersRoyaltiesProportionalToWordCount() {
        // alice: 4 words → 4/6 ≈ 0.667
        // bob:   2 words → 2/6 ≈ 0.333
        let partitions = [
            makePartition(id: "p1", documentId: "docA", ownerId: "alice", text: "one two three four"),
            makePartition(id: "p2", documentId: "docB", ownerId: "bob",   text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)

        let alice = contribution.owners.first(where: { $0.ownerId == "alice" })!
        let bob   = contribution.owners.first(where: { $0.ownerId == "bob" })!

        XCTAssertEqual(alice.royalty, 4.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(bob.royalty,   2.0 / 6.0, accuracy: 0.001)
    }

    func testThreeOwnersRoyaltiesSumToOne() {
        let partitions = [
            makePartition(id: "p1", documentId: "d1", ownerId: "a", text: "word1 word2 word3"),
            makePartition(id: "p2", documentId: "d2", ownerId: "b", text: "word4 word5"),
            makePartition(id: "p3", documentId: "d3", ownerId: "c", text: "word6 word7 word8 word9"),
        ]
        let contribution = gita.royalty(for: partitions)

        let total = contribution.owners.reduce(0.0) { $0 + $1.royalty }
        XCTAssertEqual(total, 1.0, accuracy: 0.001,
            "All royalties must sum to 1.0")
    }

    func testSingleOwnerMultipleDocumentsFullRoyalty() {
        let partitions = [
            makePartition(id: "p1", documentId: "docA", ownerId: "alice", text: "hello world"),
            makePartition(id: "p2", documentId: "docB", ownerId: "alice", text: "foo bar baz"),
        ]
        let contribution = gita.royalty(for: partitions)

        XCTAssertEqual(contribution.owners.count, 1)
        XCTAssertEqual(contribution.owners.first!.royalty, 1.0, accuracy: 0.001)
    }

    // MARK: - Determinism

    func testRoyaltyIsDeterministic() {
        let partitions = [
            makePartition(id: "p1", documentId: "d1", ownerId: "alice", text: "hello world foo"),
            makePartition(id: "p2", documentId: "d2", ownerId: "bob",   text: "bar baz"),
        ]
        let r1 = gita.royalty(for: partitions)
        let r2 = gita.royalty(for: partitions)

        let alice1 = r1.owners.first(where: { $0.ownerId == "alice" })?.royalty ?? 0
        let alice2 = r2.owners.first(where: { $0.ownerId == "alice" })?.royalty ?? 0
        XCTAssertEqual(alice1, alice2, accuracy: 0.0001,
            "Royalty calculation must be deterministic for the same input")
    }

    // MARK: - Owner metadata

    func testOwnerDocumentIdsContainsCorrectDocuments() {
        let partitions = [
            makePartition(id: "p1", documentId: "aliceDoc1", ownerId: "alice", text: "a b c d"),
            makePartition(id: "p2", documentId: "aliceDoc2", ownerId: "alice", text: "e f g h"),
            makePartition(id: "p3", documentId: "bobDoc",    ownerId: "bob",   text: "i j"),
        ]
        let contribution = gita.royalty(for: partitions)
        let alice = contribution.owners.first(where: { $0.ownerId == "alice" })!

        XCTAssertEqual(alice.documentIds.count, 2)
        XCTAssertTrue(alice.documentIds.contains("aliceDoc1"))
        XCTAssertTrue(alice.documentIds.contains("aliceDoc2"))
    }

    func testOwnerInfluenceValuesNormalized() {
        // alice has 2 documents with equal word counts → each gets 0.5 influence
        let partitions = [
            makePartition(id: "p1", documentId: "doc1", ownerId: "alice", text: "a b"),
            makePartition(id: "p2", documentId: "doc2", ownerId: "alice", text: "c d"),
        ]
        let contribution = gita.royalty(for: partitions)
        let alice = contribution.owners.first(where: { $0.ownerId == "alice" })!

        let totalInfluence = alice.influence.values.reduce(0.0, +)
        XCTAssertEqual(totalInfluence, 1.0, accuracy: 0.001,
            "Per-document influence values must sum to 1.0 for a single owner")
    }

    func testNoPeerSourceWhenAllLocal() {
        let partitions = [
            makePartition(id: "p1", documentId: "d1", ownerId: "alice", text: "hello"),
        ]
        let contribution = gita.royalty(for: partitions, peerSources: [:])
        let owner = contribution.owners.first!
        XCTAssertTrue(owner.threadId.isEmpty,
            "threadId must be empty when all partitions are local")
    }

    // MARK: - New contribution fields default to zero before pricing

    func testRoyaltyContributionCostFieldsAreZeroBeforePricing() {
        let partitions = [
            makePartition(id: "p1", documentId: "d1", ownerId: "alice", text: "hello world"),
        ]
        let contribution = gita.royalty(for: partitions)

        XCTAssertEqual(contribution.totalPayout,   0, "totalPayout must be 0 before priceContribution runs")
        XCTAssertEqual(contribution.serviceCharge, 0, "serviceCharge must be 0 before priceContribution runs")
        XCTAssertEqual(contribution.totalCost,     0, "totalCost must be 0 before priceContribution runs")
        XCTAssertNil(contribution.ledger,             "ledger must be nil before priceContribution runs")
    }

    func testOwnerEarningIsZeroBeforePricing() {
        let partitions = [
            makePartition(id: "p1", documentId: "d1", ownerId: "alice", text: "hello"),
        ]
        let contribution = gita.royalty(for: partitions)
        let owner = contribution.owners.first!
        XCTAssertEqual(owner.earning, 0, "owner.earning must be 0 until priceContribution runs")
    }

    // MARK: - Co-ownership equal split

    func testCoOwnedDocumentSplitsEquallyBetweenTwoOwners() {
        // doc-shared: 4 words, owned by alice and bob → each gets 2 effective words.
        let partitions = [
            makePartition(id: "p1", documentId: "doc-shared", ownerId: "alice", text: "one two three four"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-shared": ["alice", "bob"]]
        let contribution = gita.royalty(for: partitions, coOwners: coOwners)

        let alice = contribution.owners.first(where: { $0.ownerId == "alice" })
        let bob   = contribution.owners.first(where: { $0.ownerId == "bob" })
        XCTAssertNotNil(alice, "alice must appear as a royalty recipient")
        XCTAssertNotNil(bob,   "bob must appear as a royalty recipient even though he is not partition.ownerId")
        XCTAssertEqual(alice!.royalty, 0.5, accuracy: 0.001)
        XCTAssertEqual(bob!.royalty,   0.5, accuracy: 0.001)
    }

    func testCoOwnedDocumentThreeWaySplitIsEqual() {
        let partitions = [
            makePartition(id: "p1", documentId: "doc-shared", ownerId: "alice", text: "a b c"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-shared": ["alice", "bob", "charlie"]]
        let contribution = gita.royalty(for: partitions, coOwners: coOwners)

        XCTAssertEqual(contribution.owners.count, 3)
        for owner in contribution.owners {
            XCTAssertEqual(owner.royalty, 1.0 / 3.0, accuracy: 0.001,
                "\(owner.ownerId ?? owner.threadId) must receive exactly 1/3 of the royalty")
        }
    }

    func testCoOwnershipRoyaltiesSumToOne() {
        // doc-shared (6 words) split between alice and bob → 3 effective each.
        // doc-solo   (3 words) owned by charlie alone.
        // Total = 9 effective words: alice=3/9, bob=3/9, charlie=3/9.
        let partitions = [
            makePartition(id: "p1", documentId: "doc-shared", ownerId: "alice", text: "one two three four five six"),
            makePartition(id: "p2", documentId: "doc-solo",   ownerId: "charlie", text: "seven eight nine"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-shared": ["alice", "bob"]]
        let contribution = gita.royalty(for: partitions, coOwners: coOwners)

        let total = contribution.owners.reduce(0.0) { $0 + $1.royalty }
        XCTAssertEqual(total, 1.0, accuracy: 0.001, "royalties must sum to 1.0 with co-ownership")
        XCTAssertEqual(contribution.owners.count, 3)
    }

    func testMixedSingleAndCoOwnedDocuments() {
        // doc-A (4 words): sole owner alice.
        // doc-B (4 words): co-owned by bob and charlie.
        // Effective totals: alice=4, bob=2, charlie=2 out of 8.
        let partitions = [
            makePartition(id: "p1", documentId: "doc-A", ownerId: "alice", text: "w1 w2 w3 w4"),
            makePartition(id: "p2", documentId: "doc-B", ownerId: "bob",   text: "w5 w6 w7 w8"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-B": ["bob", "charlie"]]
        let contribution = gita.royalty(for: partitions, coOwners: coOwners)

        let alice   = contribution.owners.first(where: { $0.ownerId == "alice" })!
        let bob     = contribution.owners.first(where: { $0.ownerId == "bob" })!
        let charlie = contribution.owners.first(where: { $0.ownerId == "charlie" })!

        XCTAssertEqual(alice.royalty,   4.0 / 8.0, accuracy: 0.001)
        XCTAssertEqual(bob.royalty,     2.0 / 8.0, accuracy: 0.001)
        XCTAssertEqual(charlie.royalty, 2.0 / 8.0, accuracy: 0.001)
    }

    func testCoOwnedDocumentInfluenceNormalized() {
        // alice co-owns doc-A (4 words) and sole-owns doc-B (4 words).
        // Her effective word count: 2 from doc-A + 4 from doc-B = 6.
        // influence[doc-A] = 2/6, influence[doc-B] = 4/6.
        let partitions = [
            makePartition(id: "p1", documentId: "doc-A", ownerId: "alice", text: "a b c d"),
            makePartition(id: "p2", documentId: "doc-B", ownerId: "alice", text: "e f g h"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-A": ["alice", "bob"]]
        let contribution = gita.royalty(for: partitions, coOwners: coOwners)

        let alice = contribution.owners.first(where: { $0.ownerId == "alice" })!
        let totalInfluence = alice.influence.values.reduce(0.0, +)
        XCTAssertEqual(totalInfluence, 1.0, accuracy: 0.001,
            "influence values must still sum to 1.0 for a co-owning owner")
        XCTAssertEqual(alice.influence["doc-A"] ?? 0, 2.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(alice.influence["doc-B"] ?? 0, 4.0 / 6.0, accuracy: 0.001)
    }

    func testCoOwnerAppearsInDocumentIds() {
        let partitions = [
            makePartition(id: "p1", documentId: "doc-shared", ownerId: "alice", text: "hello world"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-shared": ["alice", "bob"]]
        let contribution = gita.royalty(for: partitions, coOwners: coOwners)

        let bob = contribution.owners.first(where: { $0.ownerId == "bob" })!
        XCTAssertTrue(bob.documentIds.contains("doc-shared"),
            "bob's documentIds must include the co-owned document")
    }

    func testEmptyCoOwnersMapPreservesOriginalBehaviour() {
        // Passing coOwners: [:] must be identical to the no-coOwners call.
        let partitions = [
            makePartition(id: "p1", documentId: "doc1", ownerId: "alice", text: "one two three"),
            makePartition(id: "p2", documentId: "doc2", ownerId: "bob",   text: "four five"),
        ]
        let withEmpty  = gita.royalty(for: partitions, coOwners: [:])
        let withNone   = gita.royalty(for: partitions)

        let aliceEmpty = withEmpty.owners.first(where: { $0.ownerId == "alice" })!.royalty
        let aliceNone  = withNone.owners.first(where: { $0.ownerId == "alice" })!.royalty
        XCTAssertEqual(aliceEmpty, aliceNone, accuracy: 0.0001,
            "empty coOwners map must be identical to no coOwners map")
    }

    // MARK: - documentEarnings with co-ownership

    func testDocumentEarningsAccumulateAcrossCoOwners() {
        // doc-shared (4 words) split between alice and bob; charlie is the requester (spender).
        // Both co-owners are non-spenders → documentEarnings[doc-shared] == totalPayout.
        let partitions = [
            makePartition(id: "p1", documentId: "doc-shared", ownerId: "alice", text: "a b c d"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-shared": ["alice", "bob"]]
        let unpriced = gita.royalty(for: partitions, coOwners: coOwners)

        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 100, completionTokens: 0)
        let priced = gita.priceContribution(unpriced, ledger: ledger,
                                             strategy: .flat(0),
                                             request: SewnRequest(ownerId: "charlie", scope: .personal, callerApp: nil))

        let earnings = gita.documentEarnings(from: priced)
        XCTAssertEqual(earnings["doc-shared"] ?? 0, priced.totalPayout, accuracy: 0.001,
            "documentEarnings for the shared doc must equal the total payout across both co-owners")
    }

    func testDocumentEarningsExcludesSpenderCoOwner() {
        // doc-shared is co-owned by alice (requester) and bob.
        // alice's earning is excluded from documentEarnings since she is the spender.
        let partitions = [
            makePartition(id: "p1", documentId: "doc-shared", ownerId: "alice", text: "a b c d"),
        ]
        let coOwners: [DocumentID: Set<OwnerID>] = ["doc-shared": ["alice", "bob"]]
        let unpriced = gita.royalty(for: partitions, coOwners: coOwners)

        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 100, completionTokens: 0)
        let priced = gita.priceContribution(unpriced, ledger: ledger,
                                             strategy: .flat(0),
                                             request: SewnRequest(ownerId: "alice", scope: .personal, callerApp: nil))

        let earnings = gita.documentEarnings(from: priced)
        let bobEarning = priced.owners.first(where: { $0.ownerId == "bob" })?.earning ?? 0
        XCTAssertEqual(earnings["doc-shared"] ?? 0, bobEarning, accuracy: 0.001,
            "only bob's share must appear in documentEarnings when alice is the spender")
    }
}
