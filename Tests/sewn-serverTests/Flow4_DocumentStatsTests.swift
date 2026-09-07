//
//  Flow4_DocumentStatsTests.swift
//  sewn-serverTests
//
//  Tests for `Sewn.DocumentStats` and `SewnRegistry` performance accumulation
//  introduced alongside the partition-based Sinatra ML refactor:
//
//  1. `PartitionSentiment` struct — averageSentiment prior, accumulation, encode/decode.
//  2. `DocumentStats.partitionSentiments` field — init default, encode/decode round-trip.
//  3. `SewnRegistry.addPerformance` — additive (not replace) across two calls for
//     retrievalCount, sentimentSum, partitionRetrievalCount, and partitionSentiments.
//  4. `RetrievalDataCollector.recordInteraction` — returned DocumentStats carries
//     updated partitionSentiments keyed by the parked item's partition ID.
//  5. `RetrievalDataCollector.generateFeatureVector` — the avg_sentiment feature
//     reflects per-partition history rather than the neutral 0.5 prior once a
//     real sentiment value is provided in documentStats.
//

import XCTest
@testable import sewn_server

final class Flow4_DocumentStatsTests: XCTestCase {

    // MARK: - PartitionSentiment

    func testPartitionSentimentDefaultsToNeutralPrior() {
        let ps = Sewn.DocumentStats.PartitionSentiment()
        XCTAssertEqual(ps.retrievalCount, 0)
        XCTAssertEqual(ps.sentimentSum, 0.0, accuracy: 1e-9)
        XCTAssertNil(ps.lastRetrieved)
        XCTAssertEqual(ps.averageSentiment, 0.5, accuracy: 1e-9,
            "averageSentiment must return 0.5 neutral prior when no retrievals recorded")
    }

    func testPartitionSentimentAverageWithOneReading() {
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 1
        ps.sentimentSum   = 0.8
        XCTAssertEqual(ps.averageSentiment, 0.8, accuracy: 1e-9)
    }

    func testPartitionSentimentAverageWithMultipleReadings() {
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 4
        ps.sentimentSum   = 2.8    // 0.7 per reading on average
        XCTAssertEqual(ps.averageSentiment, 0.7, accuracy: 1e-9)
    }

    func testPartitionSentimentEncodeDecode() throws {
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 3
        ps.sentimentSum   = 1.8
        ps.lastRetrieved  = Date(timeIntervalSince1970: 1_700_000_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ps)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Sewn.DocumentStats.PartitionSentiment.self, from: data)

        XCTAssertEqual(decoded.retrievalCount, 3)
        XCTAssertEqual(decoded.sentimentSum, 1.8, accuracy: 1e-9)
        let decodedTs = decoded.lastRetrieved?.timeIntervalSince1970 ?? 0
        let originalTs = ps.lastRetrieved?.timeIntervalSince1970 ?? 0
        XCTAssertEqual(decodedTs, originalTs, accuracy: 1.0)
        XCTAssertEqual(decoded.averageSentiment, ps.averageSentiment, accuracy: 1e-9)
    }

    func testPartitionSentimentDecodesFromEmptyObjectWithDefaults() throws {
        // Old persisted data has no partition_sentiments fields — must decode cleanly.
        let json = "{}".data(using: .utf8)!
        let ps = try JSONDecoder().decode(Sewn.DocumentStats.PartitionSentiment.self, from: json)
        XCTAssertEqual(ps.retrievalCount, 0)
        XCTAssertEqual(ps.sentimentSum, 0.0, accuracy: 1e-9)
        XCTAssertEqual(ps.averageSentiment, 0.5, accuracy: 1e-9)
    }

    // MARK: - DocumentStats.partitionSentiments field

    func testDocumentStatsDefaultHasEmptyPartitionSentiments() {
        let stats = Sewn.DocumentStats(id: "doc1")
        XCTAssertTrue(stats.partitionSentiments.isEmpty,
            "A freshly created DocumentStats must have no partition sentiments")
    }

    func testDocumentStatsEncodesAndDecodesPartitionSentiments() throws {
        var stats = Sewn.DocumentStats(id: "doc1")
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 2
        ps.sentimentSum   = 1.4
        stats.partitionSentiments["partitionA"] = ps

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(stats)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Sewn.DocumentStats.self, from: data)

        XCTAssertEqual(decoded.partitionSentiments.count, 1)
        let decodedPS = decoded.partitionSentiments["partitionA"]
        XCTAssertNotNil(decodedPS)
        XCTAssertEqual(decodedPS?.retrievalCount, 2)
        XCTAssertEqual(decodedPS?.sentimentSum ?? 0, 1.4, accuracy: 1e-9)
        XCTAssertEqual(decodedPS?.averageSentiment ?? 0, 0.7, accuracy: 1e-9)
    }

    func testDocumentStatsDecodesFromLegacyJsonWithoutPartitionSentiments() throws {
        // Simulate a persisted DocumentStats that predates the partitionSentiments field.
        let json = """
        {"id":"doc1","total_earned":0,"retrieval_count":3,"sentiment_sum":2.1}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let stats = try decoder.decode(Sewn.DocumentStats.self, from: json)
        XCTAssertTrue(stats.partitionSentiments.isEmpty,
            "Legacy JSON without partition_sentiments must decode to an empty map")
        XCTAssertEqual(stats.retrievalCount, 3)
    }

    // MARK: - SewnRegistry.addPerformance — additive accumulation

    func testAddPerformanceAccumulatesRetrievalCountAcrossTwoCycles() {
        var registry = SewnRegistry()

        // First prepare() cycle: 2 retrievals for doc1.
        var update1 = Sewn.DocumentStats(id: "doc1")
        update1.retrievalCount = 2
        update1.sentimentSum   = 1.6
        registry.addPerformance(["doc1": update1])

        // Second prepare() cycle: 1 more retrieval.
        var update2 = Sewn.DocumentStats(id: "doc1")
        update2.retrievalCount = 1
        update2.sentimentSum   = 0.7
        registry.addPerformance(["doc1": update2])

        let stats = registry.documentStats["doc1"]!
        XCTAssertEqual(stats.retrievalCount, 3,
            "retrievalCount must ADD across cycles, not replace")
        XCTAssertEqual(stats.sentimentSum, 2.3, accuracy: 1e-9,
            "sentimentSum must ADD across cycles, not replace")
        XCTAssertEqual(stats.averageSentiment, 2.3 / 3.0, accuracy: 1e-9)
    }

    func testAddPerformancePreservesTotalEarned() {
        var registry = SewnRegistry()
        // Pre-seed some earnings.
        registry.documentStats["doc1"] = Sewn.DocumentStats(id: "doc1", totalEarned: 50)

        var update = Sewn.DocumentStats(id: "doc1")
        update.retrievalCount = 1
        update.sentimentSum   = 0.8
        registry.addPerformance(["doc1": update])

        XCTAssertEqual(registry.documentStats["doc1"]?.totalEarned, 50,
            "addPerformance must never touch totalEarned — that is owned by addEarnings")
    }

    func testAddPerformanceMergesPartitionRetrievalCountAdditively() {
        var registry = SewnRegistry()

        var update1 = Sewn.DocumentStats(id: "doc1")
        update1.partitionRetrievalCount = ["pA": 3, "pB": 1]
        registry.addPerformance(["doc1": update1])

        var update2 = Sewn.DocumentStats(id: "doc1")
        update2.partitionRetrievalCount = ["pA": 2, "pC": 4]
        registry.addPerformance(["doc1": update2])

        let counts = registry.documentStats["doc1"]!.partitionRetrievalCount
        XCTAssertEqual(counts["pA"], 5, "pA: 3+2 = 5")
        XCTAssertEqual(counts["pB"], 1, "pB: 1+0 = 1 — must survive second cycle")
        XCTAssertEqual(counts["pC"], 4, "pC: 0+4 = 4 — new partition from second cycle")
    }

    func testAddPerformanceMergesPartitionSentimentsAdditively() {
        var registry = SewnRegistry()

        var ps1 = Sewn.DocumentStats.PartitionSentiment()
        ps1.retrievalCount = 2; ps1.sentimentSum = 1.6
        var update1 = Sewn.DocumentStats(id: "doc1")
        update1.partitionSentiments["pX"] = ps1
        registry.addPerformance(["doc1": update1])

        var ps2 = Sewn.DocumentStats.PartitionSentiment()
        ps2.retrievalCount = 1; ps2.sentimentSum = 0.9
        var update2 = Sewn.DocumentStats(id: "doc1")
        update2.partitionSentiments["pX"] = ps2
        registry.addPerformance(["doc1": update2])

        let merged = registry.documentStats["doc1"]!.partitionSentiments["pX"]!
        XCTAssertEqual(merged.retrievalCount, 3, "2+1 = 3")
        XCTAssertEqual(merged.sentimentSum, 2.5, accuracy: 1e-9, "1.6+0.9 = 2.5")
        XCTAssertEqual(merged.averageSentiment, 2.5 / 3.0, accuracy: 1e-9)
    }

    func testAddPerformanceMergesMultiplePartitionsFromSameCycle() {
        var registry = SewnRegistry()

        var ps1 = Sewn.DocumentStats.PartitionSentiment()
        ps1.retrievalCount = 1; ps1.sentimentSum = 0.8
        var ps2 = Sewn.DocumentStats.PartitionSentiment()
        ps2.retrievalCount = 1; ps2.sentimentSum = 0.3
        var update = Sewn.DocumentStats(id: "doc1")
        update.partitionSentiments["pPositive"] = ps1
        update.partitionSentiments["pNegative"] = ps2
        registry.addPerformance(["doc1": update])

        let stats = registry.documentStats["doc1"]!
        XCTAssertEqual(stats.partitionSentiments["pPositive"]?.averageSentiment ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(stats.partitionSentiments["pNegative"]?.averageSentiment ?? 0, 0.3, accuracy: 1e-9)
    }

    func testAddPerformanceIsolatedAcrossDocuments() {
        var registry = SewnRegistry()

        var updateA = Sewn.DocumentStats(id: "docA")
        updateA.retrievalCount = 2
        var updateB = Sewn.DocumentStats(id: "docB")
        updateB.retrievalCount = 5
        registry.addPerformance(["docA": updateA, "docB": updateB])

        XCTAssertEqual(registry.documentStats["docA"]?.retrievalCount, 2)
        XCTAssertEqual(registry.documentStats["docB"]?.retrievalCount, 5)
    }

    // MARK: - RetrievalDataCollector.recordInteraction — partition sentiment tracking

    func testRecordInteractionPopulatesPartitionSentiments() {
        var collector = RetrievalDataCollector()
        let parked = SinatraTrainingData.Parked(
            id: "partition-X",
            documentId: "doc1",
            distance: 0.3
        )
        let sentiment = Sinatra.Sentiment(
            sentiment: .positive,
            emotionalTones: [],
            reactionTypes: [],
            keyPhrases: [],
            confidence: 0.85,
            notes: ""
        )

        let stats = collector.recordInteraction(
            parked: parked,
            sentiment: sentiment,
            responseLength: 200,
            effectiveWeight: 0.8
        )

        let ps = stats.partitionSentiments["partition-X"]
        XCTAssertNotNil(ps, "partitionSentiments must contain an entry for the parked partition ID")
        XCTAssertEqual(ps?.retrievalCount, 1)
        XCTAssertEqual(ps?.sentimentSum ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(ps?.averageSentiment ?? 0, 0.8, accuracy: 1e-9)
    }

    func testRecordInteractionAccumulatesPartitionSentimentsForSamePartition() {
        var collector = RetrievalDataCollector()
        let parked = SinatraTrainingData.Parked(
            id: "partition-Y",
            documentId: "doc1",
            distance: 0.2
        )
        let sentiment = Sinatra.Sentiment(
            sentiment: .positive, emotionalTones: [], reactionTypes: [],
            keyPhrases: [], confidence: 0.9, notes: ""
        )

        // First interaction
        let stats1 = collector.recordInteraction(
            parked: parked, sentiment: sentiment, responseLength: 100, effectiveWeight: 0.7
        )
        // Second interaction — pass previous stats as existingStats
        let stats2 = collector.recordInteraction(
            parked: parked, sentiment: sentiment, responseLength: 100, effectiveWeight: 0.9,
            existingStats: stats1
        )

        let ps = stats2.partitionSentiments["partition-Y"]!
        XCTAssertEqual(ps.retrievalCount, 2, "Two interactions must accumulate to retrievalCount=2")
        XCTAssertEqual(ps.sentimentSum, 1.6, accuracy: 1e-9, "0.7+0.9 = 1.6")
        XCTAssertEqual(ps.averageSentiment, 0.8, accuracy: 1e-9)
    }

    func testRecordInteractionPartitionSentimentKeyIsPartitionIdNotDocumentId() {
        var collector = RetrievalDataCollector()
        let parked = SinatraTrainingData.Parked(
            id: "the-partition-id",
            documentId: "the-document-id",
            distance: 0.4
        )
        let sentiment = Sinatra.Sentiment(
            sentiment: .neutral, emotionalTones: [], reactionTypes: [],
            keyPhrases: [], confidence: 0.5, notes: ""
        )

        let stats = collector.recordInteraction(
            parked: parked, sentiment: sentiment, responseLength: 50, effectiveWeight: 0.5
        )

        XCTAssertNotNil(stats.partitionSentiments["the-partition-id"],
            "partitionSentiments must be keyed by partition ID, not document ID")
        XCTAssertNil(stats.partitionSentiments["the-document-id"],
            "document ID must NOT appear as a key in partitionSentiments")
    }

    // MARK: - RetrievalDataCollector.generateFeatureVector — partition sentiment in vector

    func testGenerateFeatureVectorUsesNeutralPriorWhenNoPartitionStats() {
        var collector = RetrievalDataCollector()
        // Build enough interaction history to unlock feature vector generation (≥20).
        buildHistory(&collector, count: 25)

        let vector = collector.generateFeatureVector(
            partitionId: "unknown-partition",
            documentId: "unknown-doc",
            documentStats: [:]
        )

        XCTAssertNotNil(vector, "Feature vector must be generated when history >= 20")
        // avg_sentiment is the 12th feature (index 11).
        XCTAssertEqual(vector![11], 0.5, accuracy: 1e-9,
            "avg_sentiment must default to 0.5 neutral prior when partition has no recorded history")
    }

    func testGenerateFeatureVectorUsesPartitionSpecificSentiment() {
        var collector = RetrievalDataCollector()
        buildHistory(&collector, count: 25)

        // Build a DocumentStats entry that has a strong positive signal for "part-A".
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 4
        ps.sentimentSum   = 3.2   // averageSentiment = 0.8
        var docStats = Sewn.DocumentStats(id: "doc1")
        docStats.partitionSentiments["part-A"] = ps

        let vector = collector.generateFeatureVector(
            partitionId: "part-A",
            documentId: "doc1",
            documentStats: ["doc1": docStats]
        )

        XCTAssertNotNil(vector)
        XCTAssertEqual(vector![11], 0.8, accuracy: 1e-9,
            "avg_sentiment feature must reflect per-partition history (0.8), not the neutral 0.5 prior")
    }

    func testGenerateFeatureVectorDifferentPartitionsGetDifferentSentimentFeatures() {
        var collector = RetrievalDataCollector()
        buildHistory(&collector, count: 25)

        var psPositive = Sewn.DocumentStats.PartitionSentiment()
        psPositive.retrievalCount = 2; psPositive.sentimentSum = 1.8  // avg = 0.9

        var psNegative = Sewn.DocumentStats.PartitionSentiment()
        psNegative.retrievalCount = 2; psNegative.sentimentSum = 0.4  // avg = 0.2

        var docStats = Sewn.DocumentStats(id: "doc1")
        docStats.partitionSentiments["liked"]   = psPositive
        docStats.partitionSentiments["disliked"] = psNegative
        let stats = ["doc1": docStats]

        let vecPositive = collector.generateFeatureVector(partitionId: "liked",    documentId: "doc1", documentStats: stats)
        let vecNegative = collector.generateFeatureVector(partitionId: "disliked", documentId: "doc1", documentStats: stats)
        let vecUnknown  = collector.generateFeatureVector(partitionId: "new",      documentId: "doc1", documentStats: stats)

        XCTAssertEqual(vecPositive![11], 0.9, accuracy: 1e-9, "liked partition avg_sentiment = 0.9")
        XCTAssertEqual(vecNegative![11], 0.2, accuracy: 1e-9, "disliked partition avg_sentiment = 0.2")
        XCTAssertEqual(vecUnknown![11],  0.5, accuracy: 1e-9, "unknown partition falls back to neutral 0.5")
    }

    func testGenerateFeatureVectorReturnsNilBelow20Interactions() {
        var collector = RetrievalDataCollector()
        buildHistory(&collector, count: 19)

        let vector = collector.generateFeatureVector(
            partitionId: "p1",
            documentId: "doc1",
            documentStats: [:]
        )
        XCTAssertNil(vector, "Feature vector must be nil when interaction history < 20")
    }

    // MARK: - SinatraInference documentId default

    func testSinatraInferenceDocumentIdDefaultsToEmpty() {
        let inference = SinatraInference(partitionId: "p1", distance: 0.5)
        XCTAssertEqual(inference.documentId, "",
            "documentId must default to empty string when not specified")
    }

    // MARK: - sinatra.infer() passes documentStats to feature generation

    func testInferWithDocumentStatsStillReturnsUnadjustedWhenNoModel() {
        let sinatra = Sinatra(logger: .test)
        var ps = Sewn.DocumentStats.PartitionSentiment()
        ps.retrievalCount = 5; ps.sentimentSum = 4.0
        var docStats = Sewn.DocumentStats(id: "doc1")
        docStats.partitionSentiments["p1"] = ps

        let inference = SinatraInference(partitionId: "p1", documentId: "doc1", distance: 0.4)
        let result = sinatra.infer(inference, registry: nil, documentStats: ["doc1": docStats], request: .test())

        XCTAssertEqual(result.adjustedDistance, 0.4, accuracy: 1e-6,
            "Without a trained model, documentStats must not affect the result — still unadjusted")
        XCTAssertFalse(result.applied)
    }

    // MARK: - SewnFlow.frank

    func testSewnFlowFrankServiceName() {
        let flow = SewnLogger.SewnFlow.frank(partitionId: "abc123")
        XCTAssertEqual(flow.serviceName, "Flow: Frank")
    }

    func testSewnFlowFrankExposesPartitionId() {
        let flow = SewnLogger.SewnFlow.frank(partitionId: "my-partition")
        XCTAssertEqual(flow.partitionId, "my-partition")
    }

    func testSewnFlowFrankDocumentIdIsNil() {
        let flow = SewnLogger.SewnFlow.frank(partitionId: "p")
        XCTAssertNil(flow.documentId,
            "frank flow must not expose a documentId — it carries partitionId instead")
    }

    func testSewnFlowChatAndEmbedPartitionIdIsNil() {
        XCTAssertNil(SewnLogger.SewnFlow.chat.partitionId)
        XCTAssertNil(SewnLogger.SewnFlow.embed(documentId: "doc1").partitionId)
    }

    func testSewnFlowEmbedDocumentIdIsCorrect() {
        let flow = SewnLogger.SewnFlow.embed(documentId: "doc-xyz")
        XCTAssertEqual(flow.documentId, "doc-xyz")
        XCTAssertNil(flow.partitionId)
    }

    // MARK: - Private helpers

    /// Builds `count` synthetic interaction records in `collector` using alternating
    /// positive/negative weights. Sufficient history is required before
    /// `generateFeatureVector` will return a non-nil result (minimum 20).
    private func buildHistory(_ collector: inout RetrievalDataCollector, count: Int) {
        let sentiment = Sinatra.Sentiment(
            sentiment: .neutral, emotionalTones: [], reactionTypes: [],
            keyPhrases: [], confidence: 0.5, notes: ""
        )
        for i in 0..<count {
            let weight = i % 2 == 0 ? 0.7 : 0.4
            let parked = SinatraTrainingData.Parked(
                id: "seed-partition-\(i)",
                documentId: "seed-doc",
                distance: 0.3
            )
            collector.recordInteraction(
                parked: parked, sentiment: sentiment,
                responseLength: 100, effectiveWeight: weight
            )
        }
    }
}
