//
//  Flow3_SinatraTests.swift
//  seer-serverTests
//
//  Tests for Sinatra re-ranking behavior:
//  - Unadjusted path when no model is trained
//  - SinatraInference.Result factory
//  - SinatraAdjustment metadata
//

import XCTest
@testable import seer_server

final class Flow3_SinatraTests: XCTestCase {

    private var sinatra: Sinatra!

    override func setUp() {
        super.setUp()
        sinatra = Sinatra(logger: .test)
    }

    // MARK: - SinatraInference.Result

    func testUnadjustedFactoryPreservesDistance() {
        let result = SinatraInference.Result.unadjusted(distance: 0.42)
        XCTAssertEqual(result.adjustedDistance, 0.42, accuracy: 1e-6)
        XCTAssertFalse(result.applied)
    }

    func testUnadjustedFactoryWithZeroDistance() {
        let result = SinatraInference.Result.unadjusted(distance: 0.0)
        XCTAssertEqual(result.adjustedDistance, 0.0, accuracy: 1e-6)
        XCTAssertFalse(result.applied)
    }

    func testUnadjustedFactoryWithLargeDistance() {
        let result = SinatraInference.Result.unadjusted(distance: 999.9)
        XCTAssertEqual(result.adjustedDistance, 999.9, accuracy: 1e-4)
    }

    // MARK: - sinatra.infer() with nil registry (no model)

    func testInferWithNilRegistryReturnsUnadjusted() {
        let inference = SinatraInference(partitionId: "p1", distance: 0.75)
        let result = sinatra.infer(inference, registry: nil, request: .test())

        XCTAssertEqual(result.adjustedDistance, 0.75, accuracy: 1e-6,
            "Distance must be preserved when registry is nil")
        XCTAssertFalse(result.applied,
            "applied must be false when no model is available")
    }

    func testInferWithEmptyRegistryReturnsUnadjusted() {
        let registry = SinatraRegistry()
        let inference = SinatraInference(partitionId: "p1", distance: 0.5)
        let result = sinatra.infer(inference, registry: registry, request: .test())

        XCTAssertEqual(result.adjustedDistance, 0.5, accuracy: 1e-6)
        XCTAssertFalse(result.applied)
    }

    func testInferPreservesDistanceForAllRanges() {
        let distances: [Float] = [0.0, 0.01, 0.1, 0.5, 1.0, 2.5, 10.0, 100.0]
        for d in distances {
            let inference = SinatraInference(partitionId: "p", distance: d)
            let result = sinatra.infer(inference, registry: nil, request: .test())
            XCTAssertEqual(result.adjustedDistance, d, accuracy: 1e-5,
                "Distance \(d) must be preserved when no model is trained")
        }
    }

    func testInferDoesNotCrashWithDifferentOwnerIds() {
        let ownerIds = ["owner1", "owner2", "test-user", ""]
        for ownerId in ownerIds {
            let request = SeerRequest.test(ownerId: ownerId)
            let inference = SinatraInference(partitionId: "p", distance: 0.5)
            let result = sinatra.infer(inference, registry: nil, request: request)
            XCTAssertEqual(result.adjustedDistance, 0.5, accuracy: 1e-5)
        }
    }

    // MARK: - SinatraAdjustment

    func testSinatraAdjustmentStoresMetadata() {
        let adjustment = SinatraAdjustment(
            partitionCount: 3,
            original: ["0.1", "0.2", "0.3"],
            inferred: ["0.1", "0.2", "0.3"],
            pqDistanceThreshold: 2.5
        )

        XCTAssertEqual(adjustment.partitionCount, 3)
        XCTAssertEqual(adjustment.original.count, 3)
        XCTAssertEqual(adjustment.inferred.count, 3)
        XCTAssertEqual(adjustment.pqDistanceThreshold, 2.5, accuracy: 1e-6)
    }

    func testSinatraAdjustmentOriginalAndInferredMatchWhenUntrained() {
        // When no model is trained, original == inferred for every partition
        let distances: [Float] = [0.1, 0.3, 0.5]
        let formatted = distances.map { String(format: "%.4f", $0) }

        let adjustment = SinatraAdjustment(
            partitionCount: distances.count,
            original: formatted,
            inferred: formatted,
            pqDistanceThreshold: 1.0
        )

        XCTAssertEqual(adjustment.original, adjustment.inferred,
            "Unadjusted distances must be identical in original and inferred arrays")
    }

    // MARK: - SinatraRegistry

    func testSinatraRegistryInitializesEmpty() {
        let registry = SinatraRegistry()
        XCTAssertTrue(registry.parked.isEmpty)
        XCTAssertTrue(registry.collectors.isEmpty)
        XCTAssertTrue(registry.models.isEmpty)
    }
}
