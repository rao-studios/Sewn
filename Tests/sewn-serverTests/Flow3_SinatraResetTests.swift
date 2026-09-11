//
//  Flow3_SinatraResetTests.swift
//  sewn-serverTests
//
//  Tests for Sinatra.removeOwner() — the full-profile reset that backs
//  the POST /v1/frank/reset route.
//
//  Covers:
//    1. All eight registry fields are cleared for the target owner.
//    2. Data belonging to other owners is untouched.
//    3. Calling reset on an owner with no data is a safe no-op (returns false).
//    4. Calling reset twice is idempotent.
//    5. lastSentiments and lastSearchEntries (fields added after the original
//       removeOwner implementation) are correctly cleared.
//    6. lastTrajectories (added with the trajectory snapshot feature) is cleared.
//

import XCTest
@testable import sewn_server

final class Flow3_SinatraResetTests: XCTestCase {

    private var sinatra: Sinatra!
    private let owner = SewnRegistry.Owner(id: "test-owner")
    private let otherOwner = SewnRegistry.Owner(id: "other-owner")

    override func setUp() {
        super.setUp()
        sinatra = Sinatra(logger: .test)
        // Discard anything seedFromDisk loaded from a previous test run.
        // updateRegistry is synchronous for the in-memory snapshot, so
        // subsequent test logic sees a guaranteed blank slate.
        sinatra.removeOwner(id: owner.id)
        sinatra.removeOwner(id: otherOwner.id)
    }

    override func tearDown() {
        sinatra.removeOwner(id: owner.id)
        sinatra.removeOwner(id: otherOwner.id)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Seeds the registry with a full set of Sinatra state for `owner`.
    private func seedOwner() {
        sinatra.updateRegistry { reg in
            // parked
            reg.parked[self.owner] = [
                SinatraTrainingData.Parked(
                    id: "p1",
                    partitionCompressedEmbedding: nil,
                    distance: 0.5
                )
            ]
            // collector
            reg.collectors[self.owner] = RetrievalDataCollector()
            // dataset
            var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
            try? ds.addDataPoint(input: [0.5], output: [0.8])
            reg.dataSets[self.owner] = ds
            // model (trained)
            var model = GBTModel(hyperparameters: GBTHyperparameters())
            let result = GBTTrainer.train(data: ds, params: GBTHyperparameters())
            model.trees = result.trees
            model.initialPrediction = result.initialPrediction
            reg.models[self.owner] = model
            // harmony memory
            reg.harmonyMemories[self.owner] = HarmonyMemory()
            // last sentiment
            reg.lastSentiments[self.owner] = Sinatra.Sentiment(
                sentiment: .positive,
                emotionalTones: [],
                reactionTypes: [],
                keyPhrases: [],
                confidence: 0.9,
                notes: "test"
            )
            // last search entries
            reg.lastSearchEntries[self.owner] = [
                SinatraAdjustment.Entry(
                    partitionId: "p1",
                    originalDistance: 0.5,
                    adjustedDistance: 0.4,
                    threshold: 1.0
                )
            ]
            // last trajectory
            reg.lastTrajectories[self.owner] = SinatraTrajectorySnapshot(
                paceScore: 0.7,
                responseLatencySeconds: 4.2,
                assistantResponseWordCount: 30,
                attentivenessScore: 0.8,
                referencedContent: true,
                answeredPosedQuestion: nil,
                building: false,
                posedQuestion: nil,
                engagementComposite: 0.76,
                trainingDecision: .train,
                sessionBoundaryDetected: false,
                sessionBoundaryReason: nil,
                resonanceExcerpt: nil,
                resonanceDocumentId: nil
            )
        }
    }

    // MARK: - Tests

    func testResetClearsAllEightFields() {
        seedOwner()

        // Pre-condition: all fields are populated.
        let before = sinatra.registry!
        XCTAssertNotNil(before.parked[owner])
        XCTAssertNotNil(before.collectors[owner])
        XCTAssertNotNil(before.dataSets[owner])
        XCTAssertNotNil(before.models[owner])
        XCTAssertNotNil(before.harmonyMemories[owner])
        XCTAssertNotNil(before.lastSentiments[owner])
        XCTAssertNotNil(before.lastSearchEntries[owner])
        XCTAssertNotNil(before.lastTrajectories[owner])

        let hadData = sinatra.removeOwner(id: owner.id)
        XCTAssertTrue(hadData, "removeOwner must return true when data existed")

        let after = sinatra.registry!
        XCTAssertNil(after.parked[owner],             "parked must be cleared")
        XCTAssertNil(after.collectors[owner],         "collector must be cleared")
        XCTAssertNil(after.dataSets[owner],           "dataset must be cleared")
        XCTAssertNil(after.models[owner],             "GBT model must be cleared")
        XCTAssertNil(after.harmonyMemories[owner],    "harmony memory must be cleared")
        XCTAssertNil(after.lastSentiments[owner],     "last sentiment must be cleared")
        XCTAssertNil(after.lastSearchEntries[owner],  "last search entries must be cleared")
        XCTAssertNil(after.lastTrajectories[owner],   "last trajectory must be cleared")
    }

    func testResetDoesNotAffectOtherOwners() {
        // Seed both owners.
        seedOwner()
        sinatra.updateRegistry { reg in
            reg.collectors[self.otherOwner] = RetrievalDataCollector()
            reg.harmonyMemories[self.otherOwner] = HarmonyMemory()
        }

        sinatra.removeOwner(id: owner.id)

        let after = sinatra.registry!
        XCTAssertNotNil(after.collectors[otherOwner],
            "Other owner's collector must survive a reset of a different owner")
        XCTAssertNotNil(after.harmonyMemories[otherOwner],
            "Other owner's harmony memory must survive a reset of a different owner")
    }

    func testResetOnEmptyOwnerReturnsFalse() {
        // Registry is empty — no data for this owner.
        let hadData = sinatra.removeOwner(id: owner.id)
        XCTAssertFalse(hadData,
            "removeOwner must return false when the owner had no data")
    }

    func testResetIsIdempotent() {
        seedOwner()

        let first  = sinatra.removeOwner(id: owner.id)
        let second = sinatra.removeOwner(id: owner.id)

        XCTAssertTrue(first,   "First reset must find and clear data")
        XCTAssertFalse(second, "Second reset must be a no-op (already empty)")

        // Registry must still be intact for other owners (none here, just ensure no crash).
        let reg = sinatra.registry!
        XCTAssertNil(reg.parked[owner])
        XCTAssertNil(reg.models[owner])
    }

    func testResetClearsLastSentimentAndSearchEntries() {
        // Focused test: only populate the two fields added after the original
        // removeOwner implementation to guard against regression.
        sinatra.updateRegistry { reg in
            reg.lastSentiments[self.owner] = Sinatra.Sentiment(
                sentiment: .negative,
                emotionalTones: [],
                reactionTypes: [],
                keyPhrases: [],
                confidence: 0.6,
                notes: ""
            )
            reg.lastSearchEntries[self.owner] = [
                SinatraAdjustment.Entry(
                    partitionId: "p-only",
                    originalDistance: 1.0,
                    adjustedDistance: 1.2,
                    threshold: 2.0
                )
            ]
        }

        let hadData = sinatra.removeOwner(id: owner.id)
        XCTAssertTrue(hadData)

        let after = sinatra.registry!
        XCTAssertNil(after.lastSentiments[owner],    "lastSentiment must be cleared by reset")
        XCTAssertNil(after.lastSearchEntries[owner], "lastSearchEntries must be cleared by reset")
    }

    func testResetOwnerLeavesNoTraceForThatOwner() {
        // Seeds exactly one test owner, resets it, then verifies every
        // registry key for that owner is nil. Other owners in the registry
        // (e.g. real persisted data) are intentionally ignored — we only
        // assert the target owner is fully erased.
        seedOwner()
        sinatra.removeOwner(id: owner.id)

        let reg = sinatra.registry!
        XCTAssertNil(reg.parked[owner],             "parked must be nil after reset")
        XCTAssertNil(reg.collectors[owner],         "collector must be nil after reset")
        XCTAssertNil(reg.dataSets[owner],           "dataset must be nil after reset")
        XCTAssertNil(reg.models[owner],             "model must be nil after reset")
        XCTAssertNil(reg.harmonyMemories[owner],    "harmony memory must be nil after reset")
        XCTAssertNil(reg.lastSentiments[owner],     "last sentiment must be nil after reset")
        XCTAssertNil(reg.lastSearchEntries[owner],  "last search entries must be nil after reset")
        XCTAssertNil(reg.lastTrajectories[owner],   "last trajectory must be nil after reset")
    }
}
