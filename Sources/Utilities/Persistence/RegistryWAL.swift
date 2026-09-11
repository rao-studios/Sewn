import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - RegistryWALRecord

/// One billing mutation to the `SewnRegistry`. Emitted on every hot-path billing write
/// and replayed at startup to restore mutations since the last checkpoint.
///
/// Document registration records (documentRegistered, ownerLinked) have been removed —
/// Thread is now the source of truth for document/group data.
enum RegistryWALRecord {

    // MARK: - Nested types

    /// Compact performance delta stored in the WAL.
    struct WALStats {
        let documentId: DocumentID
        let retrievalCount: Int
        let sentimentSum: Double
        let lastRetrieved: Date?
        let partitionRetrievalCount: [String: Int]
        let partitionSentiments: [String: Sewn.DocumentStats.PartitionSentiment]

        init(from stats: Sewn.DocumentStats) {
            documentId              = stats.id
            retrievalCount          = stats.retrievalCount
            sentimentSum            = stats.sentimentSum
            lastRetrieved           = stats.lastRetrieved
            partitionRetrievalCount = stats.partitionRetrievalCount
            partitionSentiments     = stats.partitionSentiments
        }
    }

    // MARK: - Cases

    /// Credits earned by one or more documents in a single billing cycle.
    case earningsAccumulated([(documentId: DocumentID, credits: Double)])

    /// Per-document performance deltas from a single `Sinatra.prepare` cycle.
    case performanceAccumulated([WALStats])
}

// MARK: - Replay

extension RegistryWALRecord {
    func apply(to registry: inout SewnRegistry) {
        switch self {
        case .earningsAccumulated(let items):
            let earnings: [DocumentID: Gita.Credits] = Dictionary(uniqueKeysWithValues: items)
            registry.addEarnings(earnings)

        case .performanceAccumulated(let stats):
            var updates: [DocumentID: Sewn.DocumentStats] = [:]
            for s in stats {
                updates[s.documentId] = Sewn.DocumentStats(
                    id:                      s.documentId,
                    retrievalCount:          s.retrievalCount,
                    sentimentSum:            s.sentimentSum,
                    lastRetrieved:           s.lastRetrieved,
                    partitionRetrievalCount: s.partitionRetrievalCount,
                    partitionSentiments:     s.partitionSentiments
                )
            }
            registry.addPerformance(updates)
        }
    }
}

// MARK: - Binary encoding

extension RegistryWALRecord {

    fileprivate enum TypeCode: UInt8 {
        // 0x01 and 0x02 were documentRegistered / ownerLinked — now retired.
        // Kept as numeric comments so the WAL can skip old records gracefully.
        case earningsAccumulated    = 0x03
        case performanceAccumulated = 0x04
    }

    var typeCode: UInt8 {
        switch self {
        case .earningsAccumulated:    return TypeCode.earningsAccumulated.rawValue
        case .performanceAccumulated: return TypeCode.performanceAccumulated.rawValue
        }
    }

    func encodePayload() -> Data {
        var buf = Data()
        switch self {

        case .earningsAccumulated(let items):
            buf.walUInt16(UInt16(clamping: items.count))
            for (documentId, credits) in items {
                buf.walString(documentId)
                buf.walDouble(credits)
            }

        case .performanceAccumulated(let stats):
            buf.walUInt16(UInt16(clamping: stats.count))
            for s in stats {
                buf.walString(s.documentId)
                buf.walInt32(Int32(clamping: s.retrievalCount))
                buf.walDouble(s.sentimentSum)
                buf.walOptionalDate(s.lastRetrieved)
                buf.walUInt16(UInt16(clamping: s.partitionRetrievalCount.count))
                for (partitionId, count) in s.partitionRetrievalCount {
                    buf.walString(partitionId)
                    buf.walInt32(Int32(clamping: count))
                }
                buf.walUInt16(UInt16(clamping: s.partitionSentiments.count))
                for (partitionId, ps) in s.partitionSentiments {
                    buf.walString(partitionId)
                    buf.walInt32(Int32(clamping: ps.retrievalCount))
                    buf.walDouble(ps.sentimentSum)
                    buf.walOptionalDate(ps.lastRetrieved)
                }
            }
        }
        return buf
    }

    static func decodePayload(typeCode: UInt8, data: Data) throws -> RegistryWALRecord {
        var r = RegistryBinaryReader(data: data)
        switch typeCode {

        case TypeCode.earningsAccumulated.rawValue:
            let count = Int(try r.uint16())
            var items: [(documentId: DocumentID, credits: Double)] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                let documentId = try r.string()
                let credits    = try r.double()
                items.append((documentId, credits))
            }
            return .earningsAccumulated(items)

        case TypeCode.performanceAccumulated.rawValue:
            let count = Int(try r.uint16())
            var stats: [WALStats] = []
            stats.reserveCapacity(count)
            for _ in 0..<count {
                let documentId     = try r.string()
                let retrievalCount = Int(try r.int32())
                let sentimentSum   = try r.double()
                let lastRetrieved  = try r.optionalDate()

                let prcCount = Int(try r.uint16())
                var prc: [String: Int] = [:]
                prc.reserveCapacity(prcCount)
                for _ in 0..<prcCount {
                    let partitionId = try r.string()
                    let count       = Int(try r.int32())
                    prc[partitionId] = count
                }

                let psCount = Int(try r.uint16())
                var ps: [String: Sewn.DocumentStats.PartitionSentiment] = [:]
                ps.reserveCapacity(psCount)
                for _ in 0..<psCount {
                    let partitionId  = try r.string()
                    var sentiment    = Sewn.DocumentStats.PartitionSentiment()
                    sentiment.retrievalCount = Int(try r.int32())
                    sentiment.sentimentSum   = try r.double()
                    sentiment.lastRetrieved  = try r.optionalDate()
                    ps[partitionId] = sentiment
                }

                stats.append(WALStats(
                    from: Sewn.DocumentStats(
                        id:                      documentId,
                        retrievalCount:          retrievalCount,
                        sentimentSum:            sentimentSum,
                        lastRetrieved:           lastRetrieved,
                        partitionRetrievalCount: prc,
                        partitionSentiments:     ps
                    )
                ))
            }
            return .performanceAccumulated(stats)

        default:
            throw RegistryWAL.WALError.unknownTypeCode(typeCode)
        }
    }
}

// MARK: - RegistryWAL

final class RegistryWAL: @unchecked Sendable {

    enum WALError: Error {
        case openFailed(Int32)
        case writeFailed(Int32)
        case truncateFailed(Int32)
        case truncatedRecord
        case checksumMismatch
        case unknownTypeCode(UInt8)
    }

    private let fd: Int32
    private(set) var byteSize: Int

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawFd = open(url.path, O_RDWR | O_CREAT | O_APPEND,
                         S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard rawFd >= 0 else { throw WALError.openFailed(errno) }
        fd = rawFd
        var s = stat()
        fstat(fd, &s)
        byteSize = Int(s.st_size)
    }

    deinit { close(fd) }

    // MARK: - Write

    func append(_ record: RegistryWALRecord) throws {
        let payload  = record.encodePayload()
        let checksum = registryAdler32(payload)

        var buf = Data(capacity: 9 + payload.count)
        buf.walUInt8(record.typeCode)
        buf.walUInt32(UInt32(payload.count))
        buf.append(payload)
        buf.walUInt32(checksum)

        let n = buf.withUnsafeBytes { ptr -> Int in
            Foundation.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard n == buf.count else { throw WALError.writeFailed(errno) }
        byteSize += buf.count
    }

    // MARK: - Read

    func readAll() throws -> [RegistryWALRecord] {
        guard byteSize > 0 else { return [] }

        var fileData = Data(count: byteSize)
        let n = fileData.withUnsafeMutableBytes { ptr -> Int in
            pread(fd, ptr.baseAddress!, byteSize, 0)
        }
        guard n > 0 else { return [] }
        let available = n

        var records: [RegistryWALRecord] = []
        var offset = 0

        while offset + 9 <= available {
            let typeCode   = fileData[offset]
            let payloadLen = Int(
                UInt32(fileData[offset + 1])         |
                (UInt32(fileData[offset + 2]) << 8)  |
                (UInt32(fileData[offset + 3]) << 16) |
                (UInt32(fileData[offset + 4]) << 24)
            )
            offset += 5

            guard offset + payloadLen + 4 <= available else { break }

            let payload = fileData[offset ..< (offset + payloadLen)]
            offset += payloadLen

            let stored = UInt32(fileData[offset])
                       | (UInt32(fileData[offset + 1]) << 8)
                       | (UInt32(fileData[offset + 2]) << 16)
                       | (UInt32(fileData[offset + 3]) << 24)
            offset += 4

            guard registryAdler32(payload) == stored else { break }

            // Skip retired record types (0x01 documentRegistered, 0x02 ownerLinked)
            // rather than halting replay — earnings records may follow them in old WAL files.
            guard let rec = try? RegistryWALRecord.decodePayload(typeCode: typeCode, data: payload)
            else { continue }
            records.append(rec)
        }
        return records
    }

    // MARK: - Checkpoint truncation

    func truncate() throws {
        guard ftruncate(fd, 0) == 0 else { throw WALError.truncateFailed(errno) }
        byteSize = 0
    }
}

// MARK: - Adler-32

private func registryAdler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
        a = (a &+ UInt32(byte)) % 65521
        b = (b &+ a) % 65521
    }
    return (b << 16) | a
}

// MARK: - BinaryReader

private struct RegistryBinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) { self.data = data }

    mutating func uint8() throws -> UInt8 {
        guard offset < data.count else { throw RegistryWAL.WALError.truncatedRecord }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func uint16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw RegistryWAL.WALError.truncatedRecord }
        defer { offset += 2 }
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    mutating func uint32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw RegistryWAL.WALError.truncatedRecord }
        defer { offset += 4 }
        let i = data.startIndex + offset
        return UInt32(data[i])          |
              (UInt32(data[i+1]) << 8)  |
              (UInt32(data[i+2]) << 16) |
              (UInt32(data[i+3]) << 24)
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func uint64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw RegistryWAL.WALError.truncatedRecord }
        defer { offset += 8 }
        let i = data.startIndex + offset
        let lo: UInt64 = UInt64(data[i])
                       | (UInt64(data[i+1]) << 8)
                       | (UInt64(data[i+2]) << 16)
                       | (UInt64(data[i+3]) << 24)
        let hi: UInt64 = UInt64(data[i+4])
                       | (UInt64(data[i+5]) << 8)
                       | (UInt64(data[i+6]) << 16)
                       | (UInt64(data[i+7]) << 24)
        return lo | (hi << 32)
    }

    mutating func double() throws -> Double {
        Double(bitPattern: try uint64())
    }

    mutating func string() throws -> String {
        let len = Int(try uint16())
        guard offset + len <= data.count else { throw RegistryWAL.WALError.truncatedRecord }
        defer { offset += len }
        let i = data.startIndex + offset
        return String(data: data[i ..< (i + len)], encoding: .utf8) ?? ""
    }

    mutating func optionalDate() throws -> Date? {
        let flag = try uint8()
        guard flag == 1 else { return nil }
        return Date(timeIntervalSince1970: try double())
    }
}

// MARK: - Data write helpers (little-endian)

private extension Data {
    mutating func walUInt8(_ v: UInt8)  { append(v) }
    mutating func walUInt16(_ v: UInt16) {
        append(UInt8( v       & 0xff))
        append(UInt8((v >> 8) & 0xff))
    }
    mutating func walUInt32(_ v: UInt32) {
        append(UInt8( v        & 0xff))
        append(UInt8((v >>  8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
    }
    mutating func walUInt64(_ v: UInt64) {
        append(UInt8( v        & 0xff))
        append(UInt8((v >>  8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 32) & 0xff))
        append(UInt8((v >> 40) & 0xff))
        append(UInt8((v >> 48) & 0xff))
        append(UInt8((v >> 56) & 0xff))
    }
    mutating func walInt32(_ v: Int32)  { walUInt32(UInt32(bitPattern: v)) }
    mutating func walDouble(_ v: Double) { walUInt64(v.bitPattern) }
    mutating func walString(_ s: String) {
        let bytes = Array(s.utf8.prefix(65535))
        walUInt16(UInt16(bytes.count))
        append(contentsOf: bytes)
    }
    mutating func walOptionalDate(_ d: Date?) {
        if let d {
            walUInt8(1)
            walDouble(d.timeIntervalSince1970)
        } else {
            walUInt8(0)
        }
    }
}
