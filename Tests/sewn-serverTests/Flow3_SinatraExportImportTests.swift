//
//  Flow3_SinatraExportImportTests.swift
//  sewn-serverTests
//
//  Tests for SinatraExport / importOwner() — the data structures and registry
//  logic that back POST /v1/frank/export and POST /v1/frank/import.
//
//  Covers:
//    1. SinatraExport Codable round-trip — all fields survive encode → decode.
//    2. CodingKeys are snake_case in the JSON output.
//    3. Export metadata — version, exportedAt, ownerId, and summary fields.
//    4. importOwner() writes all eight registry fields for the destination owner.
//    5. Import replaces existing data — old state is overwritten atomically.
//    6. Import does not affect other owners in the registry.
//    7. Import from an empty export clears all optional fields for the owner.
//    8. Full round-trip: exportOwner snapshot → importOwner into a different
//       owner slot → verify the destination registry matches the source data.
//    9. The ownerId embedded in the export payload is metadata only —
//       importOwner always writes to the ID passed as its `id` argument.
//

import XCTest
@testable import sewn_server

final class Flow3_SinatraExportImportTests: XCTestCase {

    private var sinatra: Sinatra!
    private let source = SewnRegistry.Owner(id: "export-source-owner")
    private let dest   = SewnRegistry.Owner(id: "export-dest-owner")
    private let other  = SewnRegistry.Owner(id: "export-other-owner")

    override func setUp() {
        super.setUp()
        sinatra = Sinatra(logger: .test)
        sinatra.removeOwner(id: source.id)
        sinatra.removeOwner(id: dest.id)
        sinatra.removeOwner(id: other.id)
    }

    override func tearDown() {
        sinatra.removeOwner(id: source.id)
        sinatra.removeOwner(id: dest.id)
        sinatra.removeOwner(id: other.id)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeParked(id: String = "p1") -> SinatraTrainingData.Parked {
        SinatraTrainingData.Parked(
            id: id,
            partitionCompressedEmbedding: nil,
            distance: 0.5
        )
    }

    private func makeDataSet() -> DataSet {
        var ds = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        try? ds.addDataPoint(input: [0.5], output: [0.8])
        try? ds.addDataPoint(input: [0.1], output: [0.9])
        return ds
    }

    private func makeTrainedModel(on ds: DataSet) -> GBTModel {
        var hp = GBTHyperparameters()
        hp.nEstimators     = 5
        hp.subsample       = 1.0
        hp.colsampleByTree = 1.0
        let result = GBTTrainer.train(data: ds, params: hp)
        var model = GBTModel(hyperparameters: hp)
        model.trees             = result.trees
        model.initialPrediction = result.initialPrediction
        return model
    }

    private func makeSentiment() -> Sinatra.Sentiment {
        Sinatra.Sentiment(
            sentiment: .positive,
            emotionalTones: [.satisfied],
            reactionTypes: [.agreement],
            keyPhrases: ["insight", "clarity"],
            confidence: 0.88,
            notes: "user seemed engaged"
        )
    }

    private func makeAdjustmentEntry() -> SinatraAdjustment.Entry {
        SinatraAdjustment.Entry(
            partitionId: "p1",
            originalDistance: 0.6,
            adjustedDistance: 0.45,
            threshold: 1.0
        )
    }

    private func makeTrajectory() -> SinatraTrajectorySnapshot {
        SinatraTrajectorySnapshot(
            paceScore: 0.72,
            responseLatencySeconds: 3.8,
            assistantResponseWordCount: 80,
            attentivenessScore: 0.85,
            referencedContent: true,
            answeredPosedQuestion: true,
            building: false,
            posedQuestion: "What do you think?",
            engagementComposite: 0.80,
            trainingDecision: .train,
            sessionBoundaryDetected: false,
            sessionBoundaryReason: nil,
            resonanceExcerpt: "Repetition creates familiarity.",
            resonanceDocumentId: "abc123"
        )
    }

    /// Seeds the source owner with a full set of Sinatra state.
    @discardableResult
    private func seedSource() -> (ds: DataSet, model: GBTModel) {
        let ds    = makeDataSet()
        let model = makeTrainedModel(on: ds)
        sinatra.updateRegistry { reg in
            reg.parked[self.source]            = [self.makeParked()]
            reg.collectors[self.source]        = RetrievalDataCollector()
            reg.dataSets[self.source]          = ds
            reg.models[self.source]            = model
            reg.harmonyMemories[self.source]   = HarmonyMemory()
            reg.lastSentiments[self.source]    = self.makeSentiment()
            reg.lastSearchEntries[self.source] = [self.makeAdjustmentEntry()]
            reg.lastTrajectories[self.source]  = self.makeTrajectory()
        }
        return (ds, model)
    }

    /// Builds a SinatraExport directly from the in-memory snapshot for `source`.
    private func buildExport() -> SinatraExport {
        let reg = sinatra.registry!
        return SinatraExport(
            ownerId:           source.id,
            parked:            reg.parked[source] ?? [],
            collector:         reg.collectors[source],
            dataSet:           reg.dataSets[source],
            model:             reg.models[source],
            harmonyMemory:     reg.harmonyMemories[source],
            lastSentiment:     reg.lastSentiments[source],
            lastSearchEntries: reg.lastSearchEntries[source] ?? [],
            lastTrajectory:    reg.lastTrajectories[source]
        )
    }

    // =========================================================================
    // MARK: - Section 1: Codable round-trip
    // =========================================================================

    func testExportRoundTripPreservesAllFields() throws {
        seedSource()
        let original = buildExport()

        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SinatraExport.self, from: data)

        XCTAssertEqual(decoded.version,  SinatraExport.currentVersion)
        XCTAssertEqual(decoded.ownerId,  original.ownerId)
        XCTAssertEqual(decoded.parked.count, original.parked.count,
            "parked count must survive encode → decode")
        XCTAssertNotNil(decoded.collector,
            "collector must survive encode → decode")
        XCTAssertEqual(decoded.dataSet?.size, original.dataSet?.size,
            "dataset size must survive encode → decode")
        XCTAssertEqual(decoded.model?.totalTrees, original.model?.totalTrees,
            "model tree count must survive encode → decode")
        XCTAssertNotNil(decoded.harmonyMemory,
            "harmony memory must survive encode → decode")
        XCTAssertEqual(decoded.lastSentiment?.confidence ?? -1,
                       original.lastSentiment?.confidence ?? -1,
                       accuracy: 0.001, "sentiment confidence must survive encode → decode")
        XCTAssertEqual(decoded.lastSearchEntries.count, original.lastSearchEntries.count,
            "search entries count must survive encode → decode")
        XCTAssertEqual(decoded.lastTrajectory?.paceScore ?? -1,
                       original.lastTrajectory?.paceScore ?? -1,
                       accuracy: 0.001, "trajectory paceScore must survive encode → decode")
    }

    func testExportRoundTripWithNilOptionals() throws {
        let export = SinatraExport(
            ownerId:           "nil-test-owner",
            parked:            [],
            collector:         nil,
            dataSet:           nil,
            model:             nil,
            harmonyMemory:     nil,
            lastSentiment:     nil,
            lastSearchEntries: [],
            lastTrajectory:    nil
        )
        let data    = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(SinatraExport.self, from: data)

        XCTAssertNil(decoded.collector,      "nil collector must round-trip as nil")
        XCTAssertNil(decoded.dataSet,        "nil dataSet must round-trip as nil")
        XCTAssertNil(decoded.model,          "nil model must round-trip as nil")
        XCTAssertNil(decoded.harmonyMemory,  "nil harmonyMemory must round-trip as nil")
        XCTAssertNil(decoded.lastSentiment,  "nil lastSentiment must round-trip as nil")
        XCTAssertNil(decoded.lastTrajectory, "nil lastTrajectory must round-trip as nil")
        XCTAssertTrue(decoded.parked.isEmpty)
        XCTAssertTrue(decoded.lastSearchEntries.isEmpty)
    }

    // =========================================================================
    // MARK: - Section 2: CodingKeys
    // =========================================================================

    func testExportCodingKeysAreSnakeCase() throws {
        // Non-optional fields are always present; check those against a minimal export.
        let minimal = SinatraExport(
            ownerId:           "snake-owner",
            parked:            [],
            collector:         nil,
            dataSet:           nil,
            model:             nil,
            harmonyMemory:     nil,
            lastSentiment:     nil,
            lastSearchEntries: [],
            lastTrajectory:    nil
        )
        let minJson = String(data: try JSONEncoder().encode(minimal), encoding: .utf8) ?? ""
        XCTAssertTrue(minJson.contains("\"exported_at\""),
            "exportedAt must encode as 'exported_at'")
        XCTAssertTrue(minJson.contains("\"owner_id\""),
            "ownerId must encode as 'owner_id'")
        XCTAssertTrue(minJson.contains("\"last_search_entries\""),
            "lastSearchEntries must encode as 'last_search_entries'")

        // Optional fields appear only when non-nil; seed a full source and verify.
        seedSource()
        let fullJson = String(data: try JSONEncoder().encode(buildExport()), encoding: .utf8) ?? ""
        XCTAssertTrue(fullJson.contains("\"data_set\""),
            "dataSet must encode as 'data_set'")
        XCTAssertTrue(fullJson.contains("\"harmony_memory\""),
            "harmonyMemory must encode as 'harmony_memory'")
        XCTAssertTrue(fullJson.contains("\"last_sentiment\""),
            "lastSentiment must encode as 'last_sentiment'")
        XCTAssertTrue(fullJson.contains("\"last_trajectory\""),
            "lastTrajectory must encode as 'last_trajectory'")
    }

    func testExportSummaryCodingKeysAreSnakeCase() throws {
        seedSource()
        let summary = buildExport().summary
        let data    = try JSONEncoder().encode(summary)
        let json    = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"exported_at\""))
        XCTAssertTrue(json.contains("\"owner_id\""))
        XCTAssertTrue(json.contains("\"parked_count\""))
        XCTAssertTrue(json.contains("\"interaction_history_count\""))
        XCTAssertTrue(json.contains("\"data_set_size\""))
        XCTAssertTrue(json.contains("\"is_trained\""))
        XCTAssertTrue(json.contains("\"total_trees\""))
        XCTAssertTrue(json.contains("\"has_harmony_memory\""))
    }

    // =========================================================================
    // MARK: - Section 3: Export metadata and summary
    // =========================================================================

    func testExportVersionIsCurrentVersion() {
        let export = SinatraExport(
            ownerId: "v-owner", parked: [], collector: nil, dataSet: nil,
            model: nil, harmonyMemory: nil, lastSentiment: nil,
            lastSearchEntries: [], lastTrajectory: nil
        )
        XCTAssertEqual(export.version, SinatraExport.currentVersion,
            "version must always equal currentVersion at construction time")
    }

    func testExportOwnerIdMatchesArgument() {
        let export = SinatraExport(
            ownerId: "specific-owner", parked: [], collector: nil, dataSet: nil,
            model: nil, harmonyMemory: nil, lastSentiment: nil,
            lastSearchEntries: [], lastTrajectory: nil
        )
        XCTAssertEqual(export.ownerId, "specific-owner")
    }

    func testSummaryParkedCountMatchesParkedArray() {
        seedSource()
        let export = buildExport()
        XCTAssertEqual(export.summary.parkedCount, export.parked.count,
            "summary.parkedCount must equal parked.count")
    }

    func testSummaryIsTrainedWhenModelHasTrees() {
        seedSource()
        let export = buildExport()
        XCTAssertTrue(export.summary.isTrained,
            "summary.isTrained must be true when the model has trees")
        XCTAssertGreaterThan(export.summary.totalTrees, 0)
    }

    func testSummaryIsNotTrainedForNilModel() {
        let export = SinatraExport(
            ownerId: "untrained", parked: [], collector: nil, dataSet: nil,
            model: nil, harmonyMemory: nil, lastSentiment: nil,
            lastSearchEntries: [], lastTrajectory: nil
        )
        XCTAssertFalse(export.summary.isTrained,
            "summary.isTrained must be false when model is nil")
        XCTAssertEqual(export.summary.totalTrees, 0)
    }

    func testSummaryHasHarmonyMemoryFlag() {
        seedSource()
        let withMemory    = buildExport()
        let withoutMemory = SinatraExport(
            ownerId: "no-hm", parked: [], collector: nil, dataSet: nil,
            model: nil, harmonyMemory: nil, lastSentiment: nil,
            lastSearchEntries: [], lastTrajectory: nil
        )
        XCTAssertTrue(withMemory.summary.hasHarmonyMemory,
            "hasHarmonyMemory must be true when harmonyMemory is non-nil")
        XCTAssertFalse(withoutMemory.summary.hasHarmonyMemory,
            "hasHarmonyMemory must be false when harmonyMemory is nil")
    }

    func testSummaryDataSetSizeMatchesDataSet() {
        seedSource()
        let export = buildExport()
        XCTAssertEqual(export.summary.dataSetSize, export.dataSet?.size ?? 0,
            "summary.dataSetSize must reflect the actual dataset row count")
    }

    // =========================================================================
    // MARK: - Section 4: importOwner() writes all registry fields
    // =========================================================================

    func testImportWritesAllEightFieldsToDestination() {
        seedSource()
        let export = buildExport()

        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertNotNil(reg.parked[dest],            "parked must be written to dest")
        XCTAssertNotNil(reg.collectors[dest],        "collector must be written to dest")
        XCTAssertNotNil(reg.dataSets[dest],          "dataset must be written to dest")
        XCTAssertNotNil(reg.models[dest],            "model must be written to dest")
        XCTAssertNotNil(reg.harmonyMemories[dest],   "harmony memory must be written to dest")
        XCTAssertNotNil(reg.lastSentiments[dest],    "last sentiment must be written to dest")
        XCTAssertNotNil(reg.lastSearchEntries[dest], "last search entries must be written to dest")
        XCTAssertNotNil(reg.lastTrajectories[dest],  "last trajectory must be written to dest")
    }

    func testImportPreservesParkedPartitionData() {
        seedSource()
        let export = buildExport()
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertEqual(
            reg.parked[dest]?.first?.id,
            reg.parked[source]?.first?.id,
            "imported parked partition id must match the source"
        )
        XCTAssertEqual(
            reg.parked[dest]?.first?.distance ?? -1,
            reg.parked[source]?.first?.distance ?? -1,
            accuracy: 0.001
        )
    }

    func testImportPreservesModelTreeCount() {
        seedSource()
        let export = buildExport()
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertEqual(
            reg.models[dest]?.totalTrees,
            reg.models[source]?.totalTrees,
            "imported model must have the same number of trees as the source"
        )
    }

    func testImportPreservesSentimentFields() {
        seedSource()
        let export = buildExport()
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertEqual(reg.lastSentiments[dest]?.confidence ?? -1,
                       reg.lastSentiments[source]?.confidence ?? -1,
                       accuracy: 0.001)
        XCTAssertEqual(reg.lastSentiments[dest]?.notes,
                       reg.lastSentiments[source]?.notes)
    }

    func testImportPreservesTrajectoryFields() {
        seedSource()
        let export = buildExport()
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertEqual(reg.lastTrajectories[dest]?.paceScore ?? -1,
                       reg.lastTrajectories[source]?.paceScore ?? -1,
                       accuracy: 0.001)
        XCTAssertEqual(reg.lastTrajectories[dest]?.engagementComposite ?? -1,
                       reg.lastTrajectories[source]?.engagementComposite ?? -1,
                       accuracy: 0.001)
    }

    // =========================================================================
    // MARK: - Section 5: Import replaces existing data
    // =========================================================================

    func testImportOverwritesExistingDestinationData() {
        // Seed dest with its own state.
        sinatra.updateRegistry { reg in
            reg.collectors[self.dest] = RetrievalDataCollector()
            reg.harmonyMemories[self.dest] = HarmonyMemory()
        }

        // Pre-condition: dest has data.
        XCTAssertNotNil(sinatra.registry?.collectors[dest])

        seedSource()
        let export = buildExport()
        sinatra.importOwner(id: dest.id, from: export)

        // Post-import: dest must reflect what was in the export (source's model).
        let reg = sinatra.registry!
        XCTAssertEqual(reg.models[dest]?.totalTrees, export.model?.totalTrees,
            "import must overwrite the destination's previous model")
    }

    // =========================================================================
    // MARK: - Section 6: Other owners are untouched
    // =========================================================================

    func testImportDoesNotAffectOtherOwners() {
        sinatra.updateRegistry { reg in
            reg.collectors[self.other] = RetrievalDataCollector()
            reg.harmonyMemories[self.other] = HarmonyMemory()
        }

        seedSource()
        let export = buildExport()
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertNotNil(reg.collectors[other],
            "other owner's collector must survive an import into a different slot")
        XCTAssertNotNil(reg.harmonyMemories[other],
            "other owner's harmony memory must survive an import into a different slot")
    }

    func testImportDoesNotAffectSourceOwner() {
        seedSource()
        let export = buildExport()

        // Import into dest, then verify source is unchanged.
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        XCTAssertNotNil(reg.parked[source],          "source parked must be intact after import to dest")
        XCTAssertNotNil(reg.models[source],          "source model must be intact after import to dest")
        XCTAssertNotNil(reg.collectors[source],      "source collector must be intact after import to dest")
    }

    // =========================================================================
    // MARK: - Section 7: Empty export clears optional fields
    // =========================================================================

    func testImportFromEmptyExportClearsOptionalFields() {
        // First seed dest so it has state.
        sinatra.updateRegistry { reg in
            reg.collectors[self.dest]      = RetrievalDataCollector()
            reg.harmonyMemories[self.dest] = HarmonyMemory()
        }

        let emptyExport = SinatraExport(
            ownerId:           "empty-source",
            parked:            [],
            collector:         nil,
            dataSet:           nil,
            model:             nil,
            harmonyMemory:     nil,
            lastSentiment:     nil,
            lastSearchEntries: [],
            lastTrajectory:    nil
        )
        sinatra.importOwner(id: dest.id, from: emptyExport)

        let reg = sinatra.registry!
        XCTAssertNil(reg.parked[dest],            "parked must be nil after empty import")
        XCTAssertNil(reg.collectors[dest],        "collector must be nil after empty import")
        XCTAssertNil(reg.dataSets[dest],          "dataset must be nil after empty import")
        XCTAssertNil(reg.models[dest],            "model must be nil after empty import")
        XCTAssertNil(reg.harmonyMemories[dest],   "harmony memory must be nil after empty import")
        XCTAssertNil(reg.lastSentiments[dest],    "last sentiment must be nil after empty import")
        XCTAssertNil(reg.lastSearchEntries[dest], "last search entries must be nil after empty import")
        XCTAssertNil(reg.lastTrajectories[dest],  "last trajectory must be nil after empty import")
    }

    // =========================================================================
    // MARK: - Section 8: Full export → import round-trip
    // =========================================================================

    func testExportImportRoundTripPreservesRegistryData() throws {
        // Seed the source owner with a rich state.
        seedSource()

        // Build the export as the route handler would.
        let export = buildExport()

        // Encode → decode (simulates JSON transit to a client and back).
        let jsonData      = try JSONEncoder().encode(export)
        let decodedExport = try JSONDecoder().decode(SinatraExport.self, from: jsonData)

        // Import into the dest owner (simulates the import route handler).
        sinatra.importOwner(id: dest.id, from: decodedExport)

        // Verify every significant field landed correctly at the destination.
        let reg = sinatra.registry!

        XCTAssertEqual(
            reg.parked[dest]?.count, reg.parked[source]?.count,
            "round-trip: parked count must match"
        )
        XCTAssertEqual(
            reg.models[dest]?.totalTrees, reg.models[source]?.totalTrees,
            "round-trip: model tree count must match"
        )
        XCTAssertEqual(
            reg.dataSets[dest]?.size, reg.dataSets[source]?.size,
            "round-trip: dataset size must match"
        )
        XCTAssertEqual(
            reg.lastSentiments[dest]?.confidence ?? -1,
            reg.lastSentiments[source]?.confidence ?? -1,
            accuracy: 0.001,
            "round-trip: sentiment confidence must match"
        )
        XCTAssertEqual(
            reg.lastSearchEntries[dest]?.count,
            reg.lastSearchEntries[source]?.count,
            "round-trip: search entry count must match"
        )
        XCTAssertEqual(
            reg.lastTrajectories[dest]?.paceScore ?? -1,
            reg.lastTrajectories[source]?.paceScore ?? -1,
            accuracy: 0.001,
            "round-trip: trajectory paceScore must match"
        )
    }

    func testRoundTripModelPredictionsAreIdentical() throws {
        seedSource()
        let export = buildExport()

        let jsonData      = try JSONEncoder().encode(export)
        let decodedExport = try JSONDecoder().decode(SinatraExport.self, from: jsonData)
        sinatra.importOwner(id: dest.id, from: decodedExport)

        let reg = sinatra.registry!
        guard let sourceModel = reg.models[source],
              let destModel   = reg.models[dest] else {
            return XCTFail("Both source and dest must have a trained model after round-trip")
        }

        // Same model should produce bit-identical predictions.
        let testInput: [Double] = [0.3]
        XCTAssertEqual(
            sourceModel.predictOne(inputs: testInput),
            destModel.predictOne(inputs: testInput),
            accuracy: 0.0001,
            "GBT predictions must be identical between source and imported model"
        )
    }

    // =========================================================================
    // MARK: - Section 9: ownerId in export payload is metadata only
    // =========================================================================

    func testImportUsesDestinationOwnerNotExportOwnerId() {
        seedSource()
        let export = buildExport()

        // export.ownerId == source.id — import into dest
        XCTAssertEqual(export.ownerId, source.id,
            "pre-condition: export.ownerId is the source owner")
        sinatra.importOwner(id: dest.id, from: export)

        let reg = sinatra.registry!
        // Data must appear at dest, not at source (beyond what was seeded).
        XCTAssertNotNil(reg.parked[dest],
            "imported data must land at the destination owner id, not the export's ownerId")

        // The source owner is still intact (it was seeded, not modified).
        // What we're verifying is that importOwner did NOT write to source.id a second time
        // just because export.ownerId == source.id.
        XCTAssertEqual(
            reg.parked[source]?.count,
            export.parked.count,
            "source owner parked count must remain as seeded — import must not re-write it"
        )
    }

    func testExportOwnerIdIsPreservedAsMetadata() throws {
        let export = SinatraExport(
            ownerId:           "alice",
            parked:            [],
            collector:         nil,
            dataSet:           nil,
            model:             nil,
            harmonyMemory:     nil,
            lastSentiment:     nil,
            lastSearchEntries: [],
            lastTrajectory:    nil
        )

        // Import into "bob".
        sinatra.importOwner(id: "bob-owner", from: export)

        // The export struct itself still carries "alice" as ownerId — it's readonly metadata.
        XCTAssertEqual(export.ownerId, "alice",
            "export.ownerId must remain 'alice' — it is the exporter's id, not the importer's")

        // Bob's slot must now have data.
        let bobOwner = SewnRegistry.Owner(id: "bob-owner")
        // (the export was empty, so all optional fields are nil — still, importOwner ran)
        let reg = sinatra.registry!
        XCTAssertNil(reg.parked[bobOwner],
            "empty parked array must not create a parked entry")

        // Clean up the ad-hoc owner seeded above.
        sinatra.removeOwner(id: "bob-owner")
    }
}
