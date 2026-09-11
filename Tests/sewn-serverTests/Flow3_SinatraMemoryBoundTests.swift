//
//  Flow3_SinatraMemoryBoundTests.swift
//  sewn-serverTests
//
//  Tests for the three Sinatra memory-bound fixes that prevent 24-hour CPU/RAM degradation:
//
//  1. Parked rolling window cap — `Sinatra.maxParkedEntries` (30).
//     The DEFER path (ambiguous+low-confidence sentiment) used to accumulate parked
//     data indefinitely. Now the oldest entries are evicted once the cap is hit.
//
//  2. DataSet sliding window cap — `DataSet.maxSize` (200).
//     `addDataPoint` previously appended forever, causing O(n·d·T) GBT training
//     cost to rise monotonically. Now points are evicted oldest-first past the cap.
//
//  3. Backward-compat decode of `SinatraTrainingData.Parked`.
//     Old persisted entries contain `queryEmbedding` and `partitionEmbedding` arrays
//     (~8 KB per entry). The new decoder silently discards those keys rather than
//     throwing, so existing on-disk registries load cleanly after the upgrade.
//

import XCTest
@testable import sewn_server

final class Flow3_SinatraMemoryBoundTests: XCTestCase {

    // MARK: - Parked rolling window

    func testParkedCapEvictsOldestWhenExceeded() {
        let sinatra = Sinatra(logger: .test)
        let ownerId = UUID().uuidString
        let request = SewnRequest.test(ownerId: ownerId)
        let cap = Sinatra.maxParkedEntries

        // Park cap + 5 items one by one so we can track insertion order.
        for i in 0..<(cap + 5) {
            sinatra.park(
                data: [(score: Float(i) * 0.01, partition: .test(id: "p\(i)"))],
                forQuery: [],
                request: request
            )
        }

        let owner = SewnRegistry.Owner(id: ownerId)
        let parked = sinatra.registry?.parked[owner] ?? []

        XCTAssertEqual(parked.count, cap,
            "Parked count must not exceed maxParkedEntries (\(cap)) after overflow")

        // The oldest entries (p0 … p4) must be gone; the newest (p5 … p(cap+4)) must survive.
        let parkedIds = Set(parked.map { $0.id })
        for i in 0..<5 {
            XCTAssertFalse(parkedIds.contains("p\(i)"),
                "p\(i) is older than the cap and must have been evicted")
        }
        for i in 5..<(cap + 5) {
            XCTAssertTrue(parkedIds.contains("p\(i)"),
                "p\(i) is within the rolling window and must be retained")
        }
    }

    func testParkedCapDoesNotEvictWhenUnderCap() {
        let sinatra = Sinatra(logger: .test)
        let ownerId = UUID().uuidString
        let request = SewnRequest.test(ownerId: ownerId)
        let count = Sinatra.maxParkedEntries - 1

        let scored: [(score: Float, partition: Sewn.Partition)] = (0..<count).map { i in
            (score: Float(i) * 0.01, partition: .test(id: "p\(i)"))
        }
        sinatra.park(data: scored, forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: ownerId)
        let parked = sinatra.registry?.parked[owner]
        XCTAssertEqual(parked?.count, count,
            "All \(count) entries must be kept when under the cap")
    }

    func testParkedCapExactlyAtCapRetainsAll() {
        let sinatra = Sinatra(logger: .test)
        let ownerId = UUID().uuidString
        let request = SewnRequest.test(ownerId: ownerId)
        let cap = Sinatra.maxParkedEntries

        let scored: [(score: Float, partition: Sewn.Partition)] = (0..<cap).map { i in
            (score: Float(i) * 0.01, partition: .test(id: "p\(i)"))
        }
        sinatra.park(data: scored, forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: ownerId)
        let parked = sinatra.registry?.parked[owner]
        XCTAssertEqual(parked?.count, cap,
            "Exactly cap entries must all be kept (cap is inclusive)")
    }

    func testParkedCapPreservesDistancesOfRetainedEntries() {
        let sinatra = Sinatra(logger: .test)
        let ownerId = UUID().uuidString
        let request = SewnRequest.test(ownerId: ownerId)
        let cap = Sinatra.maxParkedEntries

        // Park cap+1 items — the very first one ("p0", dist=0.99) must be evicted.
        var data: [(score: Float, partition: Sewn.Partition)] = [(score: 0.99, partition: .test(id: "p0"))]
        for i in 1...cap {
            data.append((score: Float(i) * 0.01, partition: .test(id: "p\(i)")))
        }
        sinatra.park(data: data, forQuery: [], request: request)

        let owner = SewnRegistry.Owner(id: ownerId)
        let parked = sinatra.registry?.parked[owner] ?? []
        XCTAssertFalse(parked.contains(where: { $0.id == "p0" }),
            "p0 (oldest) must be evicted after overflow")

        // Distances on survivors must be unchanged.
        for item in parked {
            guard let idx = Int(item.id.dropFirst()) else { continue }
            XCTAssertEqual(Double(item.distance), Double(Float(idx) * 0.01), accuracy: 1e-5,
                "Distance for \(item.id) must be preserved after window eviction")
        }
    }

    // MARK: - DataSet sliding window

    func testDataSetCapEvictsOldestWhenExceeded() throws {
        var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        let cap = DataSet.maxSize
        let extra = 10

        for i in 0..<(cap + extra) {
            try ds.addDataPoint(input: [Double(i)], output: [Double(i)], label: "pt\(i)")
        }

        XCTAssertEqual(ds.size, cap,
            "DataSet must not exceed maxSize (\(cap)) after overflow")
        // Oldest inputs (0 … extra-1) must be gone; survivors start at `extra`.
        XCTAssertEqual(ds.inputs.first?.first, Double(extra),
            "Oldest point (input=\(extra)) must now be the first entry")
        XCTAssertEqual(ds.inputs.last?.first, Double(cap + extra - 1),
            "Newest point must be the last entry")
    }

    func testDataSetCapDoesNotEvictWhenUnderCap() throws {
        var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        let count = DataSet.maxSize - 1

        for i in 0..<count {
            try ds.addDataPoint(input: [Double(i)], output: [Double(i)])
        }

        XCTAssertEqual(ds.size, count,
            "DataSet must retain all \(count) points when under the cap")
    }

    func testDataSetCapExactlyAtCapRetainsAll() throws {
        var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        let cap = DataSet.maxSize

        for i in 0..<cap {
            try ds.addDataPoint(input: [Double(i)], output: [Double(i)])
        }

        XCTAssertEqual(ds.size, cap,
            "Exactly cap points must all be kept")
        XCTAssertEqual(ds.inputs.first?.first, 0.0,
            "First point must still be present at exactly-cap fill")
    }

    func testDataSetCapLabelsStayInSyncAfterEviction() throws {
        var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        let cap = DataSet.maxSize

        for i in 0..<(cap + 3) {
            try ds.addDataPoint(input: [Double(i)], output: [Double(i)], label: "label\(i)")
        }

        XCTAssertEqual(ds.labels.count, cap,
            "Labels array must be trimmed to cap alongside inputs")
        XCTAssertEqual(ds.labels.first, "label3",
            "First surviving label must correspond to the first surviving input")
        XCTAssertEqual(ds.labels.last, "label\(cap + 2)",
            "Last label must be the most recently added")
    }

    func testDataSetOutputsStayInSyncAfterEviction() throws {
        var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        let cap = DataSet.maxSize
        let extra = 5

        for i in 0..<(cap + extra) {
            try ds.addDataPoint(input: [Double(i)], output: [Double(i) * 2.0])
        }

        // First surviving output must be 2 * extra (oldest evicted = 0…extra-1).
        XCTAssertEqual(ds.outputs?.first?.first ?? -1, Double(extra) * 2.0, accuracy: 1e-10,
            "Outputs must stay aligned with inputs after eviction")
        XCTAssertEqual(ds.outputs?.count, cap,
            "Outputs array must be trimmed to cap")
    }

    // MARK: - Backward-compat decode of Parked (legacy embedding fields)

    func testParkedDecodesLegacyJSONWithEmbeddingFields() throws {
        // Old persisted format includes queryEmbedding and partitionEmbedding arrays.
        // The new decoder must silently discard them without throwing.
        let legacyJSON = """
        {
            "id": "abc123",
            "documentId": "doc-x",
            "queryEmbedding": [0.1, 0.2, 0.3],
            "partitionEmbedding": [0.4, 0.5, 0.6],
            "partitionCompressedEmbedding": [1, 2, 3],
            "distance": 0.42,
            "parkedAt": 788918400.0
        }
        """.data(using: .utf8)!

        let parked = try JSONDecoder().decode(SinatraTrainingData.Parked.self, from: legacyJSON)

        XCTAssertEqual(parked.id, "abc123")
        XCTAssertEqual(parked.documentId, "doc-x")
        XCTAssertEqual(parked.partitionCompressedEmbedding, [1, 2, 3])
        XCTAssertEqual(Double(parked.distance), 0.42, accuracy: 1e-5)
    }

    func testParkedDecodesNewJSONWithoutEmbeddingFields() throws {
        // New format omits queryEmbedding and partitionEmbedding entirely.
        let newJSON = """
        {
            "id": "xyz789",
            "documentId": "doc-y",
            "distance": 0.15,
            "parkedAt": 788918400.0
        }
        """.data(using: .utf8)!

        let parked = try JSONDecoder().decode(SinatraTrainingData.Parked.self, from: newJSON)

        XCTAssertEqual(parked.id, "xyz789")
        XCTAssertEqual(parked.documentId, "doc-y")
        XCTAssertNil(parked.partitionCompressedEmbedding)
        XCTAssertEqual(Double(parked.distance), 0.15, accuracy: 1e-5)
    }

    func testParkedRoundtripDoesNotWriteEmbeddingFields() throws {
        let original = SinatraTrainingData.Parked(
            id: "round-trip",
            documentId: "doc-z",
            partitionCompressedEmbedding: [10, 20],
            distance: 0.33
        )

        let encoded = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        XCTAssertNil(json["queryEmbedding"],
            "queryEmbedding must not be written in the new format")
        XCTAssertNil(json["partitionEmbedding"],
            "partitionEmbedding must not be written in the new format")
        XCTAssertEqual(json["id"] as? String, "round-trip")

        // Decode back and verify round-trip fidelity.
        let decoded = try JSONDecoder().decode(SinatraTrainingData.Parked.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.documentId, original.documentId)
        XCTAssertEqual(decoded.partitionCompressedEmbedding, original.partitionCompressedEmbedding)
        XCTAssertEqual(Double(decoded.distance), Double(original.distance), accuracy: 1e-5)
    }

    func testParkedDecodesLegacyJSONMissingDocumentId() throws {
        // Very old entries may lack documentId — must fall back to "".
        let legacyJSON = """
        {
            "id": "old-entry",
            "queryEmbedding": [1.0],
            "partitionEmbedding": [2.0],
            "distance": 0.7,
            "parkedAt": 788918400.0
        }
        """.data(using: .utf8)!

        let parked = try JSONDecoder().decode(SinatraTrainingData.Parked.self, from: legacyJSON)

        XCTAssertEqual(parked.id, "old-entry")
        XCTAssertEqual(parked.documentId, "",
            "Missing documentId in old format must default to empty string")
    }
}
