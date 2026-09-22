//
//  Fixtures.swift
//  sewn-serverTests
//

import Foundation
import Logging
@testable import sewn_server

// MARK: - Persistence cleanup

/// Wipes all Sewn persistence files written by a test run.
/// Safe to call before `Sewn()` is constructed — does not touch `node-id`,
/// so shard-scoped node identity stays stable across the test session.
func wipeSewnPersistenceFiles() {
    let db = FilePersistence.getDefaultURL()
    for key in ["table", "registry", "sinatra/registry"] {
        try? FileManager.default.removeItem(at: db.appendingPathComponent(key))
    }
    if let contents = try? FileManager.default.contentsOfDirectory(
        at: db, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ) {
        for url in contents where url.lastPathComponent.hasPrefix("shard-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
    try? FileManager.default.removeItem(at: db.appendingPathComponent("personal"))
}

// MARK: - Logger

extension Logger {
    static var test: Logger {
        var logger = Logger(label: "test-sewn")
        logger.logLevel = .critical
        return logger
    }
}

extension SewnLogger {
    static var test: SewnLogger { SewnLogger(.test) }
}

// MARK: - RegistryMutator

extension RegistryMutator {
    /// Returns a RegistryMutator pre-seeded with an empty registry.
    /// Seeding sets the in-memory snapshot before any `loadedRegistry()` call,
    /// so the mutator never reads from the shared on-disk file during tests.
    static func test() -> RegistryMutator {
        let m = RegistryMutator(logger: .test, walURL: nil)
        m.seed(SewnRegistry())
        return m
    }
}

// MARK: - SewnRequest

extension SewnRequest {
    static func test(
        ownerId: String = "test-owner",
        scope: SewnRequestScope? = .personal
    ) -> SewnRequest {
        SewnRequest(ownerId: ownerId, group: nil, aggregate: nil, scope: scope, requestID: nil, callerApp: nil)
    }
}

// MARK: - Sewn.Document

extension Sewn.Document {
    static func test(
        id: String = UUID().uuidString,
        ownerId: String = "test-owner"
    ) -> Sewn.Document {
        Sewn.Document(id: id, url: URL(string: "https://example.com")!, ownerId: ownerId)
    }
}

// MARK: - Sewn.Group

extension Sewn.Group {
    static func test(
        id: String = "test-group",
        label: String = "Test Group",
        ownerId: String = "test-owner",
        metadata: Sewn.Group.Metadata? = nil
    ) -> Sewn.Group {
        Sewn.Group(id: id, label: label, ownerId: ownerId, documents: [], metadata: metadata)
    }
}

// MARK: - Sewn.Group.Metadata

extension Sewn.Group.Metadata {
    static func test(
        description: String? = "A test group description",
        tags: [String] = ["swift", "test"]
    ) -> Sewn.Group.Metadata {
        Sewn.Group.Metadata(description: description, tags: tags)
    }
}

// MARK: - Sewn.Partition

extension Sewn.Partition {
    static func test(
        id: String = UUID().uuidString,
        documentId: String = "test-doc",
        url: URL = URL(string: "https://example.com")!,
        embedding: [Float] = [],
        text: String = "test text here",
        ownerId: String = "test-owner"
    ) -> Sewn.Partition {
        Sewn.Partition(
            id: id,
            documentId: documentId,
            url: url,
            embedding: embedding,
            text: text,
            ownerId: ownerId
        )
    }
}

// MARK: - Gita.TokenLedger

extension Gita.TokenLedger {
    /// A single mistral-medium call: 100 prompt + 50 completion tokens.
    static func test(
        model: String = "mistral-medium",
        promptTokens: Int = 100,
        completionTokens: Int = 50
    ) -> Gita.TokenLedger {
        var ledger = Gita.TokenLedger()
        ledger.record(model: model, promptTokens: promptTokens, completionTokens: completionTokens)
        return ledger
    }

    /// Two-call ledger simulating a primary completion + secondary tiny call.
    static var twoCall: Gita.TokenLedger {
        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 1200, completionTokens: 340)
        ledger.record(model: "mistral-tiny",   promptTokens: 80,   completionTokens: 20)
        return ledger
    }
}

// MARK: - Vector Fixtures

/// Deterministic vector helpers for reproducible test cases.
/// All vectors use `dim = 32` — divisible by 16 (PartitionQuantizer.numSubvectors).
enum VectorFixtures {
    static let dim = 32

    /// All-zero vector.
    static func zeros() -> [Float] { [Float](repeating: 0, count: dim) }

    /// Unit vector along a single axis.
    static func unit(axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis % dim] = 1.0
        return v
    }

    /// Seeded pseudo-random vector — deterministic across runs.
    static func random(seed: UInt64) -> [Float] {
        random(dim: dim, seed: seed)
    }

    /// Seeded pseudo-random vector at an explicit dimension.
    static func random(dim: Int, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<dim).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int(bitPattern: UInt(state >> 33)) % 1000) / 500.0 - 1.0
        }
    }

    /// Vector very close to `center` (small perturbation).
    static func near(_ center: [Float], seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return center.map { c in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int(bitPattern: UInt(state >> 33)) % 100) / 100000.0
            return c + noise
        }
    }

    /// L2 distance between two vectors.
    static func l2(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { d in let e = d.0 - d.1; return e * e }.reduce(0, +).squareRoot()
    }
}

// MARK: - MockEmbeddingProvider

/// Drop-in test double for `EmbeddingProviding`.
///
/// Returns one deterministic random vector per input text so route handlers
/// can run end-to-end without hitting the network.  Seed is fixed so results
/// are reproducible across test runs.
///
/// Usage pattern for future route-level tests:
/// ```swift
/// let mock = MockEmbeddingProvider()
/// registerBatchEmbeddingsRoute(app, sewn,
///                              modelProvider: ...,
///                              embeddingModelProvider: mock)
/// try await app.test(.POST, "v1/batch/embeddings") { ... }
/// ```
actor MockEmbeddingProvider: EmbeddingProviding {
    private var callCount = 0

    func acquirePreprocessSlot() async {}
    func releasePreprocessSlot() async {}

    func run(
        _ texts: [String],
        logger: Logger,
        priority: Bool
    ) async throws -> (result: [EmbeddingData], usage: Requests.Embedding.Get.Result.Usage) {
        let embeddings = texts.enumerated().map { (i, _) -> EmbeddingData in
            let seed = UInt64(i + callCount * 1000 + 99000)
            return EmbeddingData(
                embedding: .floats(VectorFixtures.random(dim: VectorFixtures.dim, seed: seed)),
                index: i
            )
        }
        callCount += texts.count
        let usage = Requests.Embedding.Get.Result.Usage(
            promptAudioSeconds: nil,
            promptTokens: texts.count,
            totalTokens: texts.count,
            completionTokens: 0,
            requestCount: nil,
            promptTokenDetails: nil
        )
        return (embeddings, usage)
    }
}
