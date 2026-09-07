//
//  Flow4_RegistryWALTests.swift
//  sewn-serverTests
//
//  Tests for the RegistryWAL (billing-only, post-Thread overhaul):
//
//    Binary round-trip
//      • earningsAccumulated — multi-document batch
//      • performanceAccumulated — minimal (no partitions) and full (partitions + sentiments)
//
//    WAL file operations
//      • readAll() on a fresh (empty) file returns []
//      • Multiple appended records are returned in insertion order
//      • byteSize tracks cumulative bytes written
//      • truncate() resets byteSize to 0 and subsequent readAll() returns []
//      • Append after truncate writes from start
//
//    Crash / corruption recovery
//      • readAll() stops and returns the clean prefix when a checksum is bad
//      • readAll() stops at a record whose declared payload length exceeds the file
//
//    Migration compatibility
//      • readAll() skips retired type codes (0x01, 0x02) and returns valid records that follow
//
//    Registry replay (RegistryWALRecord.apply(to:))
//      • earningsAccumulated — credits added into documentStats (auto-created if absent)
//      • earningsAccumulated — second accumulation is additive
//      • performanceAccumulated — retrieval count, sentiment, and partition stats merged
//      • sequence — earnings → performance applied in order
//
//    WAL file + replay integration
//      • Append earnings + performance, re-open WAL, replay onto fresh registry
//

import XCTest
@testable import sewn_server

final class Flow4_RegistryWALTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sewn-flow15-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWAL(name: String = "test-wal") throws -> RegistryWAL {
        try RegistryWAL(url: tempDir.appendingPathComponent(name))
    }

    // MARK: - Round-trip helpers

    private func roundTrip(_ record: RegistryWALRecord) throws -> RegistryWALRecord {
        let payload = record.encodePayload()
        return try RegistryWALRecord.decodePayload(typeCode: record.typeCode, data: payload)
    }

    // MARK: - Round-trip: earningsAccumulated

    func testEarningsAccumulated_roundTrip() throws {
        let items: [(documentId: DocumentID, credits: Double)] = [
            ("doc-a", 1.5),
            ("doc-b", 0.25),
            ("doc-c", 100.0),
        ]
        let decoded = try roundTrip(.earningsAccumulated(items))

        guard case .earningsAccumulated(let out) = decoded else {
            return XCTFail("Wrong case")
        }
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].documentId, "doc-a")
        XCTAssertEqual(out[0].credits, 1.5, accuracy: 1e-9)
        XCTAssertEqual(out[1].documentId, "doc-b")
        XCTAssertEqual(out[1].credits, 0.25, accuracy: 1e-9)
        XCTAssertEqual(out[2].credits, 100.0, accuracy: 1e-9)
    }

    // MARK: - Round-trip: performanceAccumulated

    func testPerformanceAccumulated_minimal_roundTrip() throws {
        let stats = Sewn.DocumentStats(
            id: "doc-perf",
            retrievalCount: 5,
            sentimentSum: 3.75,
            lastRetrieved: nil,
            partitionRetrievalCount: [:],
            partitionSentiments: [:]
        )
        let decoded = try roundTrip(.performanceAccumulated([.init(from: stats)]))

        guard case .performanceAccumulated(let out) = decoded else {
            return XCTFail("Wrong case")
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].documentId, "doc-perf")
        XCTAssertEqual(out[0].retrievalCount, 5)
        XCTAssertEqual(out[0].sentimentSum, 3.75, accuracy: 1e-9)
        XCTAssertNil(out[0].lastRetrieved)
        XCTAssertTrue(out[0].partitionRetrievalCount.isEmpty)
        XCTAssertTrue(out[0].partitionSentiments.isEmpty)
    }

    func testPerformanceAccumulated_full_roundTrip() throws {
        let refDate = Date(timeIntervalSince1970: 1_700_000_000.5)
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 4
        ps.sentimentSum   = 2.8
        ps.lastRetrieved  = refDate

        let stats = Sewn.DocumentStats(
            id: "doc-full",
            retrievalCount: 12,
            sentimentSum: 8.4,
            lastRetrieved: refDate,
            partitionRetrievalCount: ["p-1": 7, "p-2": 5],
            partitionSentiments: ["p-1": ps]
        )
        let decoded = try roundTrip(.performanceAccumulated([.init(from: stats)]))

        guard case .performanceAccumulated(let out) = decoded else {
            return XCTFail("Wrong case")
        }
        let s = out[0]
        XCTAssertEqual(s.retrievalCount, 12)
        XCTAssertEqual(s.sentimentSum, 8.4, accuracy: 1e-9)
        XCTAssertEqual(s.lastRetrieved?.timeIntervalSince1970 ?? 0,
                       refDate.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(s.partitionRetrievalCount["p-1"], 7)
        XCTAssertEqual(s.partitionRetrievalCount["p-2"], 5)
        XCTAssertEqual(s.partitionSentiments["p-1"]?.retrievalCount, 4)
        XCTAssertEqual(s.partitionSentiments["p-1"]?.sentimentSum ?? 0, 2.8, accuracy: 1e-9)
        XCTAssertEqual(
            s.partitionSentiments["p-1"]?.lastRetrieved?.timeIntervalSince1970 ?? 0,
            refDate.timeIntervalSince1970, accuracy: 1e-6
        )
    }

    // MARK: - WAL file operations

    func testEmptyWALReadsEmptyArray() throws {
        let wal = try makeWAL()
        let records = try wal.readAll()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(wal.byteSize, 0)
    }

    func testAppendedRecordsReadBackInOrder() throws {
        let wal = try makeWAL()

        try wal.append(.earningsAccumulated([("doc-1", 1.0)]))
        try wal.append(.earningsAccumulated([("doc-2", 2.0)]))
        try wal.append(.earningsAccumulated([("doc-3", 3.0)]))

        let records = try wal.readAll()
        XCTAssertEqual(records.count, 3)

        for (i, record) in records.enumerated() {
            guard case .earningsAccumulated(let items) = record else {
                return XCTFail("Wrong case at index \(i)")
            }
            XCTAssertEqual(items[0].documentId, "doc-\(i + 1)")
            XCTAssertEqual(items[0].credits, Double(i + 1), accuracy: 1e-9)
        }
    }

    func testByteSizeIncreasesAfterEachAppend() throws {
        let wal = try makeWAL()
        XCTAssertEqual(wal.byteSize, 0)

        try wal.append(.earningsAccumulated([("doc-1", 1.0)]))
        let after1 = wal.byteSize
        XCTAssertGreaterThan(after1, 0)

        try wal.append(.earningsAccumulated([("doc-2", 2.0)]))
        XCTAssertGreaterThan(wal.byteSize, after1)
    }

    func testTruncateClearsWALAndByteSize() throws {
        let wal = try makeWAL()
        try wal.append(.earningsAccumulated([("doc-1", 1.0)]))
        try wal.append(.earningsAccumulated([("doc-2", 2.0)]))
        XCTAssertGreaterThan(wal.byteSize, 0)

        try wal.truncate()
        XCTAssertEqual(wal.byteSize, 0)

        let records = try wal.readAll()
        XCTAssertTrue(records.isEmpty)
    }

    func testAppendAfterTruncateWritesFromStart() throws {
        let wal = try makeWAL()
        try wal.append(.earningsAccumulated([("doc-before", 9.0)]))
        try wal.truncate()

        try wal.append(.earningsAccumulated([("doc-after", 7.0)]))
        let records = try wal.readAll()

        XCTAssertEqual(records.count, 1)
        guard case .earningsAccumulated(let items) = records[0] else {
            return XCTFail("Wrong case")
        }
        XCTAssertEqual(items[0].documentId, "doc-after")
    }

    // MARK: - Crash / corruption recovery

    func testReadAllStopsAtBadChecksum() throws {
        let url = tempDir.appendingPathComponent("wal-bad-checksum")

        do {
            let wal = try RegistryWAL(url: url)
            try wal.append(.earningsAccumulated([("doc-1", 1.0)]))
            try wal.append(.earningsAccumulated([("doc-2", 2.0)]))
        }

        // Overwrite the last 4 bytes (checksum of the second record).
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        try fh.seek(toOffset: fileSize - 4)
        fh.write(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        let wal2 = try RegistryWAL(url: url)
        let records = try wal2.readAll()

        XCTAssertEqual(records.count, 1)
        guard case .earningsAccumulated(let items) = records[0] else {
            return XCTFail("Wrong case")
        }
        XCTAssertEqual(items[0].documentId, "doc-1")
    }

    func testReadAllStopsAtTruncatedPayload() throws {
        let url = tempDir.appendingPathComponent("wal-truncated-payload")

        do {
            let wal = try RegistryWAL(url: url)
            try wal.append(.earningsAccumulated([("doc-1", 1.0)]))
        }

        // Append a partial record header: typeCode + payloadLen claiming 1 000 bytes,
        // but no payload or checksum follows — simulates a crash mid-write.
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        try fh.seekToEnd()
        var partial = Data()
        partial.append(0x03)                                  // typeCode: earningsAccumulated
        partial.append(contentsOf: [0xe8, 0x03, 0x00, 0x00]) // payloadLen = 1 000 LE
        fh.write(partial)

        let wal2 = try RegistryWAL(url: url)
        let records = try wal2.readAll()

        XCTAssertEqual(records.count, 1)
        guard case .earningsAccumulated(let items) = records[0] else {
            return XCTFail("Wrong case")
        }
        XCTAssertEqual(items[0].documentId, "doc-1")
    }

    // MARK: - Migration compatibility

    /// A WAL file produced before the Thread overhaul may contain retired type codes
    /// 0x01 (documentRegistered) and 0x02 (ownerLinked). readAll() must skip those
    /// records and continue processing valid records that follow.
    func testReadAllSkipsRetiredTypeCodes() throws {
        let url = tempDir.appendingPathComponent("wal-migration")

        // Build a raw WAL file:
        //   [record 0] typeCode=0x01 (retired: documentRegistered), empty payload
        //   [record 1] typeCode=0x02 (retired: ownerLinked), empty payload
        //   [record 2] valid earningsAccumulated
        var raw = Data()

        func adler32(_ data: Data) -> UInt32 {
            var a: UInt32 = 1; var b: UInt32 = 0
            for byte in data { a = (a &+ UInt32(byte)) % 65521; b = (b &+ a) % 65521 }
            return (b << 16) | a
        }
        func walUInt32(_ v: UInt32) -> Data {
            Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        func appendRecord(typeCode: UInt8, payload: Data, into buf: inout Data) {
            buf.append(typeCode)
            buf.append(contentsOf: walUInt32(UInt32(payload.count)))
            buf.append(payload)
            buf.append(contentsOf: walUInt32(adler32(payload)))
        }

        appendRecord(typeCode: 0x01, payload: Data(), into: &raw) // retired
        appendRecord(typeCode: 0x02, payload: Data(), into: &raw) // retired

        // Append a valid earningsAccumulated record using the live WAL so its encoding is correct.
        try raw.write(to: url)
        let wal = try RegistryWAL(url: url)
        try wal.append(.earningsAccumulated([("doc-migration", 42.0)]))

        // Re-open to reset byteSize from fstat.
        let wal2 = try RegistryWAL(url: url)
        let records = try wal2.readAll()

        // Only the valid earnings record should be returned; retired records are silently skipped.
        XCTAssertEqual(records.count, 1)
        guard case .earningsAccumulated(let items) = records[0] else {
            return XCTFail("Expected earningsAccumulated")
        }
        XCTAssertEqual(items[0].documentId, "doc-migration")
        XCTAssertEqual(items[0].credits, 42.0, accuracy: 1e-9)
    }

    // MARK: - Registry replay

    func testReplay_earningsAccumulated_createsAndAccumulates() throws {
        var registry = SewnRegistry()

        // First accumulation — documentStats entry does not exist yet.
        RegistryWALRecord.earningsAccumulated([("doc-earn", 12.5)]).apply(to: &registry)
        XCTAssertEqual(registry.documentStats["doc-earn"]?.totalEarned ?? 0, 12.5, accuracy: 1e-9)

        // Second accumulation is additive.
        RegistryWALRecord.earningsAccumulated([("doc-earn", 7.5)]).apply(to: &registry)
        XCTAssertEqual(registry.documentStats["doc-earn"]?.totalEarned ?? 0, 20.0, accuracy: 1e-9)
    }

    func testReplay_earningsAccumulated_multipleDocuments() throws {
        var registry = SewnRegistry()

        RegistryWALRecord.earningsAccumulated([
            ("doc-x", 5.0),
            ("doc-y", 3.0),
        ]).apply(to: &registry)

        XCTAssertEqual(registry.documentStats["doc-x"]?.totalEarned ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(registry.documentStats["doc-y"]?.totalEarned ?? 0, 3.0, accuracy: 1e-9)
    }

    func testReplay_performanceAccumulated_mergesStats() throws {
        var registry = SewnRegistry()

        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 3
        ps.sentimentSum   = 2.1
        let stats = Sewn.DocumentStats(
            id: "doc-perf-r",
            retrievalCount: 5,
            sentimentSum: 3.5,
            partitionRetrievalCount: ["part-x": 5],
            partitionSentiments: ["part-x": ps]
        )
        RegistryWALRecord.performanceAccumulated([.init(from: stats)]).apply(to: &registry)

        let result = registry.documentStats["doc-perf-r"]
        XCTAssertEqual(result?.retrievalCount, 5)
        XCTAssertEqual(result?.sentimentSum ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(result?.partitionRetrievalCount["part-x"], 5)
        XCTAssertEqual(result?.partitionSentiments["part-x"]?.retrievalCount, 3)
        XCTAssertEqual(result?.partitionSentiments["part-x"]?.sentimentSum ?? 0, 2.1, accuracy: 1e-9)
    }

    func testReplay_performanceAccumulated_isAdditive() throws {
        var registry = SewnRegistry()

        let first = Sewn.DocumentStats(id: "doc-add", retrievalCount: 4, sentimentSum: 2.0)
        RegistryWALRecord.performanceAccumulated([.init(from: first)]).apply(to: &registry)

        let second = Sewn.DocumentStats(id: "doc-add", retrievalCount: 3, sentimentSum: 1.5)
        RegistryWALRecord.performanceAccumulated([.init(from: second)]).apply(to: &registry)

        XCTAssertEqual(registry.documentStats["doc-add"]?.retrievalCount, 7)
        XCTAssertEqual(registry.documentStats["doc-add"]?.sentimentSum ?? 0, 3.5, accuracy: 1e-9)
    }

    func testReplay_earningsThenPerformance_sequence() throws {
        var registry = SewnRegistry()

        RegistryWALRecord.earningsAccumulated([("doc-seq", 5.0)]).apply(to: &registry)
        RegistryWALRecord.earningsAccumulated([("doc-seq", 3.0)]).apply(to: &registry)

        let stats = Sewn.DocumentStats(id: "doc-seq", retrievalCount: 4, sentimentSum: 2.8)
        RegistryWALRecord.performanceAccumulated([.init(from: stats)]).apply(to: &registry)

        XCTAssertEqual(registry.documentStats["doc-seq"]?.totalEarned ?? 0, 8.0, accuracy: 1e-9)
        XCTAssertEqual(registry.documentStats["doc-seq"]?.retrievalCount, 4)
        XCTAssertEqual(registry.documentStats["doc-seq"]?.sentimentSum ?? 0, 2.8, accuracy: 1e-9)
    }

    // MARK: - WAL file + replay integration

    func testAppendAndReplayViaNewWALObject() throws {
        let url = tempDir.appendingPathComponent("wal-integration")

        do {
            let wal = try RegistryWAL(url: url)
            try wal.append(.earningsAccumulated([("doc-int", 9.0)]))
            let stats = Sewn.DocumentStats(id: "doc-int", retrievalCount: 3, sentimentSum: 2.1)
            try wal.append(.performanceAccumulated([.init(from: stats)]))
        }

        let wal2 = try RegistryWAL(url: url)
        let records = try wal2.readAll()
        XCTAssertEqual(records.count, 2)

        var registry = SewnRegistry()
        for record in records { record.apply(to: &registry) }

        XCTAssertEqual(registry.documentStats["doc-int"]?.totalEarned ?? 0, 9.0, accuracy: 1e-9)
        XCTAssertEqual(registry.documentStats["doc-int"]?.retrievalCount, 3)
    }
}
