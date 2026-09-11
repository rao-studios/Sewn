//
//  Flow3_SinatraParkAlignmentTests.swift
//  sewn-serverTests
//
//  Tests for the Sinatra parking alignment fix:
//
//  Before the fix, `sinatra.park()` was called inside `PartitionTable.search()`
//  with only the top-k (default 3) results — a subset of what actually appeared
//  in the response context and in Gita contributions. After the fix, parking is
//  moved to the same site as `gita.track()` and receives the exact same partition
//  set. Three invariants are now locked in:
//
//  1. park() stores ALL passed partitions — no internal top-k cap.
//  2. Score (distance) stored per parked item matches the passed score.
//  3. Park accumulates across calls within the same owner session.
//
//  Plus pure-logic tests for the two score-merging strategies introduced at the
//  call sites:
//
//  searchWithPeers — `localScoreMap[id] ?? peerScoreMap[id]`:
//    Local score wins over peer score for shared partition IDs (local result is
//    the authoritative distance; peer result is a fallback).
//
//  searchExpanded — Dictionary(... uniquingKeysWith: min):
//    Best (lowest) distance wins when the same partition appears in results from
//    multiple query variant searches.
//

import XCTest
@testable import sewn_server

final class Flow3_SinatraParkAlignmentTests: XCTestCase {

    private var sinatra: Sinatra!
    /// Fresh UUID per test — Sinatra persists to disk, so each test must use an
    /// owner ID that has never been parked to before. This prevents disk state from
    /// a previous test run contaminating the current one.
    private var testOwnerId: String!

    override func setUp() {
        super.setUp()
        sinatra = Sinatra(logger: .test)
        testOwnerId = UUID().uuidString
    }

    private func uniqueRequest() -> SewnRequest {
        SewnRequest.test(ownerId: testOwnerId)
    }

    // MARK: - park() stores all passed partitions

    func testParkStoresAllPassedPartitions() {
        let request = uniqueRequest()
        let scored: [(score: Float, partition: Sewn.Partition)] = (0..<5).map { i in
            (score: Float(i) * 0.1, partition: .test(id: "p\(i)"))
        }

        sinatra.park(data: scored, forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let parked = sinatra.registry?.parked[owner]
        XCTAssertEqual(parked?.count, 5,
            "park() must store every passed partition — no top-k cap is applied internally. " +
            "The caller (search path) is responsible for passing exactly the set that " +
            "contributed to the response, and all of those must be available to prepare().")
    }

    func testParkWithFewerThanThreePartitionsStoresAll() {
        // Regression: the old code used .prefix(k) where k=3 — this test ensures
        // that even 1 or 2 partitions are stored, and that 4+ are also not capped.
        // Each iteration uses a fresh Sinatra and a unique ownerId to avoid disk bleed.
        for count in [1, 2, 4, 7] {
            let iterationOwnerId = UUID().uuidString
            let request = SewnRequest.test(ownerId: iterationOwnerId)
            let freshSinatra = Sinatra(logger: .test)
            let scored: [(score: Float, partition: Sewn.Partition)] = (0..<count).map { i in
                (score: Float(i) * 0.1, partition: .test(id: "p\(i)"))
            }
            freshSinatra.park(data: scored, forQuery: [], request: request)

            let owner = SewnRegistry.Owner(id: iterationOwnerId)
            let parked = freshSinatra.registry?.parked[owner]
            XCTAssertEqual(parked?.count, count,
                "park() must store all \(count) passed partitions without any cap")
        }
    }

    func testParkWithEmptyInputLeavesRegistryUnchanged() {
        let request = uniqueRequest()
        sinatra.park(data: [], forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let parked = sinatra.registry?.parked[owner]
        XCTAssertTrue(parked == nil || parked!.isEmpty,
            "park() with an empty partition list must not create a parked entry")
    }

    // MARK: - park() stores correct distances

    func testParkStoresScoreAsDistance() {
        let request = uniqueRequest()
        let scored: [(score: Float, partition: Sewn.Partition)] = [
            (score: 0.25, partition: .test(id: "near")),
            (score: 0.75, partition: .test(id: "far")),
        ]

        sinatra.park(data: scored, forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let parked = sinatra.registry?.parked[owner] ?? []

        let nearItem = parked.first { $0.id == "near" }
        let farItem  = parked.first { $0.id == "far" }

        XCTAssertNotNil(nearItem, "Partition 'near' must be present in parked data")
        XCTAssertNotNil(farItem,  "Partition 'far' must be present in parked data")
        XCTAssertEqual(Double(nearItem?.distance ?? 0), 0.25, accuracy: 1e-6,
            "Stored distance must equal the passed score — used by RetrievalDataCollector")
        XCTAssertEqual(Double(farItem?.distance ?? 0), 0.75, accuracy: 1e-6,
            "Stored distance must equal the passed score — used by RetrievalDataCollector")
    }

    func testParkPartitionIdsMatchInput() {
        let request = uniqueRequest()
        let ids = ["alpha", "beta", "gamma", "delta"]
        let scored = ids.map { id in
            (score: Float(0.1), partition: Sewn.Partition.test(id: id))
        }

        sinatra.park(data: scored, forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let parkedIds = Set(sinatra.registry?.parked[owner]?.map { $0.id } ?? [])
        XCTAssertEqual(parkedIds, Set(ids),
            "The set of parked partition IDs must exactly match the input — " +
            "this is the alignment contract: what contributed to the response is what gets trained on")
    }

    // MARK: - park() accumulates across calls

    func testParkAccumulatesAcrossMultipleCalls() {
        let request = uniqueRequest()

        sinatra.park(data: [(0.1, .test(id: "p1"))], forQuery: [], request: request)
        sinatra.park(data: [(0.2, .test(id: "p2"))], forQuery: [], request: request)
        sinatra.park(data: [(0.3, .test(id: "p3"))], forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let parked = sinatra.registry?.parked[owner]
        XCTAssertEqual(parked?.count, 3,
            "Multiple park() calls for the same owner must accumulate — each search turn " +
            "appends its partitions so that prepare() sees the full session history")
    }

    func testParkIsolatedAcrossOwners() {
        // Use unique owner IDs — Sinatra persists to disk, so hardcoded IDs bleed
        // across test runs (each run parks again into the existing on-disk state).
        let ownerAId = UUID().uuidString
        let ownerBId = UUID().uuidString
        let requestA = SewnRequest.test(ownerId: ownerAId)
        let requestB = SewnRequest.test(ownerId: ownerBId)

        sinatra.park(data: [(0.1, .test(id: "pA1")), (0.2, .test(id: "pA2"))], forQuery: [], request: requestA)
        sinatra.park(data: [(0.3, .test(id: "pB1"))], forQuery: [], request: requestB)

        let ownerA = SewnRegistry.Owner(id: ownerAId)
        let ownerB = SewnRegistry.Owner(id: ownerBId)

        XCTAssertEqual(sinatra.registry?.parked[ownerA]?.count, 2,
            "Owner A must have exactly 2 parked partitions")
        XCTAssertEqual(sinatra.registry?.parked[ownerB]?.count, 1,
            "Owner B must have exactly 1 parked partition")
    }

    // MARK: - searchWithPeers score merge: localScoreMap[id] ?? peerScoreMap[id]

    func testLocalScoreWinsOverPeerScoreForSharedPartition() {
        // When a partition appears in both local and peer results, the local distance
        // must be used. Local search is the authoritative proximity measure — peer
        // distances are from a different node's index and may use different normalisation.
        let localScoreMap: [String: Float] = ["shared": 0.3, "local-only": 0.5]
        let peerScoreMap:  [String: Float] = ["shared": 0.8, "peer-only": 0.2]

        let allPartitions: [Sewn.Partition] = [
            .test(id: "shared"),
            .test(id: "local-only"),
            .test(id: "peer-only"),
        ]

        let allScored: [(score: Float, partition: Sewn.Partition)] = allPartitions.compactMap { p in
            guard let score = localScoreMap[p.id] ?? peerScoreMap[p.id] else { return nil }
            return (score, p)
        }

        XCTAssertEqual(allScored.count, 3,
            "Every partition in allPartitions must receive a score")
        let sharedScore   = allScored.first { $0.partition.id == "shared" }?.score
        let peerOnlyScore = allScored.first { $0.partition.id == "peer-only" }?.score

        XCTAssertEqual(Double(sharedScore ?? 0), 0.3, accuracy: 1e-6,
            "Local score (0.3) must win over peer score (0.8) for the shared partition")
        XCTAssertEqual(Double(peerOnlyScore ?? 0), 0.2, accuracy: 1e-6,
            "Peer score must be used when no local score exists for that partition")
    }

    func testPartitionWithNoScoreIsExcludedFromPark() {
        // A partition that appears in allPartitions but has no entry in either
        // localScoreMap or peerScoreMap must be excluded by compactMap — this can
        // happen if a peer result was deduplicated before scores were captured.
        let localScoreMap: [String: Float] = ["p1": 0.4]
        let peerScoreMap:  [String: Float] = [:]

        let allPartitions: [Sewn.Partition] = [
            .test(id: "p1"),
            .test(id: "p2-no-score"),   // no score in either map
        ]

        let allScored: [(score: Float, partition: Sewn.Partition)] = allPartitions.compactMap { p in
            guard let score = localScoreMap[p.id] ?? peerScoreMap[p.id] else { return nil }
            return (score, p)
        }

        XCTAssertEqual(allScored.count, 1,
            "Partitions with no score entry must be excluded — compactMap must drop them")
        XCTAssertEqual(allScored.first?.partition.id, "p1")
    }

    func testLocalOnlyPartitionsAllReceiveScores() {
        // When there are no peer results, every local partition must get its score.
        let localScoreMap: [String: Float] = ["a": 0.1, "b": 0.2, "c": 0.3]
        let peerScoreMap:  [String: Float] = [:]

        let allPartitions = ["a", "b", "c"].map { Sewn.Partition.test(id: $0) }

        let allScored: [(score: Float, partition: Sewn.Partition)] = allPartitions.compactMap { p in
            guard let score = localScoreMap[p.id] ?? peerScoreMap[p.id] else { return nil }
            return (score, p)
        }

        XCTAssertEqual(allScored.count, 3,
            "All local-only partitions must receive their scores when there are no peers")
    }

    // MARK: - searchExpanded score dedup: Dictionary(... uniquingKeysWith: min)

    func testExpandedScoreMapKeepsBestScoreWhenPartitionAppearsInMultipleVariants() {
        // If variant A returns partition "p1" with distance 0.8 and variant B returns
        // "p1" with distance 0.3, the merged score map must keep 0.3 (min = closest).
        // This ensures the GBT trains with the most confident retrieval signal.
        let variantResults: [(score: Float, partition: Sewn.Partition)] = [
            (score: 0.8, partition: .test(id: "p1")),   // from variant A
            (score: 0.3, partition: .test(id: "p1")),   // from variant B — closer
            (score: 0.5, partition: .test(id: "p2")),
        ]

        let scoredByPartitionId: [String: Float] = Dictionary(
            variantResults.map { ($0.partition.id, $0.score) },
            uniquingKeysWith: min
        )

        XCTAssertEqual(Double(scoredByPartitionId["p1"] ?? 0), 0.3, accuracy: 1e-6,
            "searchExpanded must keep the best (lowest/closest) distance when a partition " +
            "appears in multiple variant results — min wins")
        XCTAssertEqual(Double(scoredByPartitionId["p2"] ?? 0), 0.5, accuracy: 1e-6,
            "Unique partition must retain its original score")
        XCTAssertEqual(scoredByPartitionId.count, 2,
            "Duplicate partition IDs must be collapsed to one entry in the score map")
    }

    func testExpandedScoreMapAllUniquePartitionsPreserved() {
        let variantResults: [(score: Float, partition: Sewn.Partition)] = (0..<5).map { i in
            (score: Float(i) * 0.1, partition: .test(id: "p\(i)"))
        }

        let scoredByPartitionId: [String: Float] = Dictionary(
            variantResults.map { ($0.partition.id, $0.score) },
            uniquingKeysWith: min
        )

        XCTAssertEqual(scoredByPartitionId.count, 5,
            "All unique partitions must appear in the score map")
    }

    func testExpandedUniquePartitionsAllGetScores() {
        // After dedup, every unique partition that survived must have a score entry
        // so compactMap produces no nils and the parked set is complete.
        let allResults: [(score: Float, partition: Sewn.Partition)] = [
            (score: 0.2, partition: .test(id: "a")),
            (score: 0.9, partition: .test(id: "a")),   // dup — 0.2 wins
            (score: 0.4, partition: .test(id: "b")),
        ]

        let scoredByPartitionId: [String: Float] = Dictionary(
            allResults.map { ($0.partition.id, $0.score) },
            uniquingKeysWith: min
        )

        var seen = Set<String>()
        let uniquePartitions = allResults.map { $0.partition }.filter { seen.insert($0.id).inserted }

        let uniqueScored: [(score: Float, partition: Sewn.Partition)] = uniquePartitions.compactMap { p in
            scoredByPartitionId[p.id].map { ($0, p) }
        }

        XCTAssertEqual(uniqueScored.count, uniquePartitions.count,
            "Every unique partition must have a score — compactMap must not drop any")
        let scoreForA = uniqueScored.first { $0.partition.id == "a" }?.score
        XCTAssertEqual(Double(scoreForA ?? 0), 0.2, accuracy: 1e-6,
            "Best score for 'a' must be 0.2 after uniquingKeysWith: min")
    }

    // MARK: - prepare() consumed-ID filter (race condition fix)
    //
    // prepare() fires as a fire-and-forget Task before search() runs.
    // The LLM sentiment call takes 2-5 seconds, during which search() completes
    // and parks new results into parked[owner]. The old code called
    // saveRegistry(updatedRegistry) at the end, clobbering those new parks.
    //
    // The fix: prepare() captures consumedIds = Set(parked.map { $0.id }) at
    // the start, then at every clear site filters:
    //   reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
    //
    // These tests verify the filter logic by directly calling updateRegistry
    // with the same pattern, simulating the race.

    func testConsumedIdFilterPreservesNewParksAddedDuringLLMCall() {
        // Simulate turn N-1: park items A and B (previous turn's search results).
        let request = uniqueRequest()
        sinatra.park(data: [
            (score: 0.2, partition: .test(id: "A")),
            (score: 0.3, partition: .test(id: "B")),
        ], forQuery: [], request: request)

        // prepare() snapshots parked and builds consumedIds.
        let owner = SewnRegistry.Owner(id: request.ownerId)
        let snapshotParked = sinatra.registry?.parked[owner] ?? []
        let consumedIds = Set(snapshotParked.map { $0.id })

        // Simulate turn N search completing mid-LLM-call: parks C and D.
        sinatra.park(data: [
            (score: 0.1, partition: .test(id: "C")),
            (score: 0.4, partition: .test(id: "D")),
        ], forQuery: [], request: request)

        // prepare() finishes — apply the consumed-ID filter.
        sinatra.updateRegistry { reg in
            let remaining = reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
            reg.parked[owner] = remaining?.isEmpty == false ? remaining : nil
        }

        let finalParked = sinatra.registry?.parked[owner] ?? []
        let finalIds = Set(finalParked.map { $0.id })

        XCTAssertFalse(finalIds.contains("A"),
            "Park A (consumed by prepare()) must be removed")
        XCTAssertFalse(finalIds.contains("B"),
            "Park B (consumed by prepare()) must be removed")
        XCTAssertTrue(finalIds.contains("C"),
            "Park C (added during LLM call) must be preserved")
        XCTAssertTrue(finalIds.contains("D"),
            "Park D (added during LLM call) must be preserved")
        XCTAssertEqual(finalParked.count, 2,
            "Only the 2 new parks must remain after the consumed-ID filter")
    }

    func testConsumedIdFilterWithNoNewParksRemovesAllConsumed() {
        // When no new parks arrive during the LLM call, the result is an empty
        // (nil) parked entry — same outcome as the old removeValue behaviour.
        let request = uniqueRequest()
        sinatra.park(data: [
            (score: 0.2, partition: .test(id: "X")),
            (score: 0.5, partition: .test(id: "Y")),
        ], forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let snapshotParked = sinatra.registry?.parked[owner] ?? []
        let consumedIds = Set(snapshotParked.map { $0.id })

        // No new parks — filter runs on the same set that was consumed.
        sinatra.updateRegistry { reg in
            let remaining = reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
            reg.parked[owner] = remaining?.isEmpty == false ? remaining : nil
        }

        let finalParked = sinatra.registry?.parked[owner]
        XCTAssertNil(finalParked,
            "parked[owner] must be nil when all parks were consumed and no new ones arrived")
    }

    func testConsumedIdFilterDoesNotAffectOtherOwners() {
        let requestA = uniqueRequest()
        let requestB = SewnRequest.test(ownerId: UUID().uuidString)

        sinatra.park(data: [(score: 0.1, partition: .test(id: "pA"))], forQuery: [], request: requestA)
        sinatra.park(data: [(score: 0.2, partition: .test(id: "pB"))], forQuery: [], request: requestB)

        let ownerA = SewnRegistry.Owner(id: requestA.ownerId)
        let ownerB = SewnRegistry.Owner(id: requestB.ownerId)

        let consumedIds = Set(["pA"])

        // Only filter owner A.
        sinatra.updateRegistry { reg in
            let remaining = reg.parked[ownerA]?.filter { !consumedIds.contains($0.id) }
            reg.parked[ownerA] = remaining?.isEmpty == false ? remaining : nil
        }

        XCTAssertNil(sinatra.registry?.parked[ownerA],
            "Owner A's consumed parks must be cleared")
        XCTAssertNotNil(sinatra.registry?.parked[ownerB],
            "Owner B's parks must be untouched by a filter scoped to owner A")
    }

    // MARK: - parkIndices()

    func testParkIndicesStoresAllEntries() {
        let request = uniqueRequest()
        let data: [(documentId: DocumentID, tagDistance: Float?, wasIncluded: Bool)] = [
            ("doc1", 0.3, true),
            ("doc2", 0.9, false),
            ("doc3", nil,  true),
        ]
        sinatra.parkIndices(data: data, request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let stored = sinatra.registry?.parkedIndices[owner]
        XCTAssertEqual(stored?.count, 3, "parkIndices() must store all passed entries")
    }

    func testParkIndicesEmptyInputIsNoOp() {
        let request = uniqueRequest()
        sinatra.parkIndices(data: [], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let stored = sinatra.registry?.parkedIndices[owner]
        XCTAssertTrue(stored == nil || stored!.isEmpty,
            "parkIndices() with empty input must not create a registry entry")
    }

    func testParkIndicesStoresCorrectFields() {
        let request = uniqueRequest()
        sinatra.parkIndices(data: [("docA", 0.42, true)], request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let entry = sinatra.registry?.parkedIndices[owner]?.first
        XCTAssertEqual(entry?.documentId, "docA")
        XCTAssertEqual(Double(entry?.tagDistance ?? 0), 0.42, accuracy: 1e-5)
        XCTAssertTrue(entry?.wasIncluded == true)
    }

    func testParkIndicesRollingWindowEvictsOldestAtCap() {
        let request = uniqueRequest()
        // Park max + 5 entries.
        let total = Sinatra.maxParkedEntries + 5
        let data = (0..<total).map { i -> (DocumentID, Float?, Bool) in
            ("doc\(i)", Float(i) * 0.01, true)
        }
        sinatra.parkIndices(data: data, request: request)

        let owner = SewnRegistry.Owner(id: request.ownerId)
        let stored = sinatra.registry?.parkedIndices[owner] ?? []
        XCTAssertEqual(stored.count, Sinatra.maxParkedEntries,
            "parkedIndices must not exceed maxParkedEntries after overflow")
        // Oldest entries (doc0…doc4) must be gone; most-recent ones must survive.
        let ids = stored.map(\.documentId)
        XCTAssertFalse(ids.contains("doc0"), "oldest entry must be evicted")
        XCTAssertTrue(ids.contains("doc\(total - 1)"), "most-recent entry must survive")
    }

    func testParkIndicesIsolatedAcrossOwners() {
        let requestA = SewnRequest.test(ownerId: UUID().uuidString)
        let requestB = SewnRequest.test(ownerId: UUID().uuidString)

        sinatra.parkIndices(data: [("docA1", 0.1, true), ("docA2", 0.2, false)], request: requestA)
        sinatra.parkIndices(data: [("docB1", 0.5, true)], request: requestB)

        let ownerA = SewnRegistry.Owner(id: requestA.ownerId)
        let ownerB = SewnRegistry.Owner(id: requestB.ownerId)
        XCTAssertEqual(sinatra.registry?.parkedIndices[ownerA]?.count, 2)
        XCTAssertEqual(sinatra.registry?.parkedIndices[ownerB]?.count, 1)
    }
}
