//
//  Flow2_GitaSpanTests.swift
//  sewn-serverTests
//
//  Tests for Gita span attribution:
//  - extractCitations: deterministic parsing of compact summary output
//  - computeSpans: three-level matching priority (compact citation → direct n-gram → similarity)
//  - Text helpers: normalise, stripMarkdown, contentWords, overlapCoefficient
//

import XCTest
@testable import sewn_server

final class Flow2_GitaSpanTests: XCTestCase {

    private var gita: Gita!

    override func setUp() {
        super.setUp()
        gita = Gita(logger: .test)
    }

    // MARK: - Helpers

    private func partition(
        id: String = UUID().uuidString,
        documentId: String = UUID().uuidString,
        sourceName: String,
        text: String,
        ownerId: String = "alice"
    ) -> Sewn.Partition {
        // URL last path component becomes the source name the compact references.
        Sewn.Partition.test(
            id: id,
            documentId: documentId,
            url: URL(string: "https://example.com/\(sourceName)")!,
            text: text,
            ownerId: ownerId
        )
    }

    // MARK: - extractCitations

    func testExtractCitationsEmptyCompactText() {
        let p = partition(sourceName: "meeting-notes", text: "some text")
        let citations = Gita.extractCitations(from: "", partitions: [p], requestOwnerId: "alice")
        XCTAssertTrue(citations.isEmpty)
    }

    func testExtractCitationsNoPartitions() {
        let citations = Gita.extractCitations(from: "In your note \"meeting-notes\", you discussed the roadmap.", partitions: [], requestOwnerId: "alice")
        XCTAssertTrue(citations.isEmpty)
    }

    func testExtractCitationsSourceNameNotMentioned() {
        // The compact text references a different source — partition should get no citation.
        let p = partition(sourceName: "travel-diary", text: "some text")
        let compact = "In your note \"startup-ideas\", you wrote about fundraising."
        let citations = Gita.extractCitations(from: compact, partitions: [p], requestOwnerId: "alice")
        XCTAssertTrue(citations.isEmpty)
    }

    func testExtractCitationsSinglePartitionMatch() {
        let p = partition(sourceName: "meeting-notes", text: "some text", ownerId: "alice")
        // "meeting-notes" normalises to "meeting notes" which appears in the compact sentence.
        let compact = """
        ### Personal Memory:
        In your note "meeting-notes", you discussed the Q3 product roadmap and timeline.
        This sentence mentions nothing relevant.
        """
        let citations = Gita.extractCitations(from: compact, partitions: [p], requestOwnerId: "alice")

        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].partitionId, p.documentId)
        // Content words from the matching sentence must include substance words.
        XCTAssertTrue(citations[0].keyWords.contains("discussed"))
        XCTAssertTrue(citations[0].keyWords.contains("roadmap"))
        XCTAssertTrue(citations[0].keyWords.contains("timeline"))
        // Stop words and source-name fragments should not dominate.
        XCTAssertFalse(citations[0].keyWords.contains("in"))
        XCTAssertFalse(citations[0].keyWords.contains("the"))
    }

    func testExtractCitationsMultiplePartitionsSeparate() {
        let p1 = partition(sourceName: "startup-ideas", text: "ideas text", ownerId: "alice")
        let p2 = partition(sourceName: "travel-diary",  text: "diary text", ownerId: "alice")
        let compact = """
        In your note "startup-ideas", you mentioned raising capital next spring.
        Someone noted in "travel-diary" that the Kyoto trip was transformative.
        """
        let citations = Gita.extractCitations(from: compact, partitions: [p1, p2], requestOwnerId: "alice")

        XCTAssertEqual(citations.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: citations.map { ($0.partitionId, $0) })

        let c1 = try! XCTUnwrap(byId[p1.documentId])
        XCTAssertTrue(c1.keyWords.contains("raising") || c1.keyWords.contains("capital"))

        let c2 = try! XCTUnwrap(byId[p2.documentId])
        XCTAssertTrue(c2.keyWords.contains("kyoto") || c2.keyWords.contains("transformative"))
    }

    func testExtractCitationsKeyWordsAccumulateAcrossSentences() {
        // If two sentences in the compact both cite the same source, the key words
        // from both sentences are collected into a single citation.
        let p = partition(sourceName: "fitness-log", text: "some text")
        let compact = """
        In your note "fitness-log", you tracked your marathon training schedule.
        Your "fitness-log" also mentioned a target of sub-four hours.
        """
        let citations = Gita.extractCitations(from: compact, partitions: [p], requestOwnerId: "alice")

        XCTAssertEqual(citations.count, 1)
        XCTAssertTrue(citations[0].keyWords.contains("marathon"))
        XCTAssertTrue(citations[0].keyWords.contains("target") || citations[0].keyWords.contains("sub"))
    }

    // MARK: - computeSpans: baseline behaviour

    func testComputeSpansEmptyResponseReturnsUnchanged() {
        let p = partition(sourceName: "doc", text: "the quick brown fox jumps over the lazy dog")
        let contribution = gita.royalty(for: [p])
        let result = Gita.computeSpans(responseText: "", contribution: contribution, partitions: [p])
        // Empty response → early return, no spans attached.
        let owner = result.owners.first!
        XCTAssertTrue(owner.spans.isEmpty)
    }

    func testComputeSpansEmptyContributionReturnsUnchanged() {
        let result = Gita.computeSpans(
            responseText: "Some response text here.",
            contribution: Gita.Contribution(owners: []),
            partitions: []
        )
        XCTAssertTrue(result.owners.isEmpty)
    }

    func testComputeSpansNoOverlapProducesNoSpans() {
        // Partition words and response words share nothing — no match at any level.
        let p = partition(sourceName: "doc", text: "xylophone rhinoceros quasar nebula vortex")
        let contribution = gita.royalty(for: [p])
        let result = Gita.computeSpans(
            responseText: "Today was sunny and warm outside the garden.",
            contribution: contribution,
            partitions: [p]
        )
        let owner = result.owners.first!
        XCTAssertTrue(owner.spans.isEmpty)
    }

    // MARK: - computeSpans: compact citation path (Step 0)

    func testComputeSpansCompactCitationFindsSpan() {
        // Raw partition text shares few words with the response, but the compact
        // citation key words match the response directly — Step 0 should fire.
        let p = partition(
            sourceName: "water-history",
            text: "ancient roman engineering techniques historical aqueducts infrastructure supply",
            ownerId: "alice"
        )
        // Compact summary distilled the key claim into the citation sentence.
        let compact = """
        In your note "water-history", you recalled that Roman aqueducts supplied clean water to cities.
        """
        let citations = Gita.extractCitations(from: compact, partitions: [p], requestOwnerId: "alice")
        XCTAssertFalse(citations.isEmpty, "Pre-condition: citation must be extracted")

        let contribution = gita.royalty(for: [p])
        // Response echoes the compact phrasing, not the raw partition text.
        let response = "Roman aqueducts supplied clean water to entire cities, which is remarkable engineering."

        let result = Gita.computeSpans(
            responseText: response,
            contribution: contribution,
            partitions: [p],
            compactCitations: citations
        )
        let owner = result.owners.first!
        XCTAssertFalse(owner.spans.isEmpty, "Compact citation match should produce a span")
    }

    func testComputeSpansCompactCitationsAreOptional() {
        // Omitting compactCitations (default []) must not crash and should still
        // find spans via the direct/similarity path when words overlap.
        let p = partition(
            sourceName: "ideas",
            text: "fundraising venture capital startup growth runway investors seed round"
        )
        let contribution = gita.royalty(for: [p])
        let response = "Fundraising runway and investor relations are key startup concerns."

        let result = Gita.computeSpans(
            responseText: response,
            contribution: contribution,
            partitions: [p]
            // no compactCitations
        )
        // With strong word overlap the similarity path should still find a span.
        let owner = result.owners.first!
        XCTAssertFalse(owner.spans.isEmpty, "Similarity path should find a span without citations")
    }

    // MARK: - computeSpans: span structure

    func testComputeSpansSpanOffsetsAreWithinResponseBounds() {
        let p = partition(
            sourceName: "health-notes",
            text: "sleep quality circadian rhythm recovery rest restoration performance"
        )
        let contribution = gita.royalty(for: [p])
        let response = "Sleep quality and recovery rest are essential for peak performance."

        let result = Gita.computeSpans(
            responseText: response,
            contribution: contribution,
            partitions: [p]
        )
        let owner = result.owners.first!
        for span in owner.spans {
            XCTAssertGreaterThanOrEqual(span.lower, 0)
            XCTAssertLessThanOrEqual(span.upper, response.count)
            XCTAssertLessThan(span.lower, span.upper)
        }
    }

    // MARK: - Text helpers

    func testNormaliseStripsAndLowercases() {
        let result = Gita.normalise("Hello, World! It's a Test.")
        // lowercased, punctuation → spaces, whitespace collapsed
        XCTAssertEqual(result, "hello world it s a test")
    }

    func testStripMarkdownRemovesBoldAndHeadings() {
        let md = "# Title\n**bold** and _italic_ text."
        let stripped = Gita.stripMarkdown(md)
        XCTAssertFalse(stripped.contains("#"))
        XCTAssertFalse(stripped.contains("**"))
        XCTAssertTrue(stripped.contains("bold"))
        XCTAssertTrue(stripped.contains("Title"))
    }

    func testContentWordsFiltersStopWordsAndShortTokens() {
        let words = Gita.contentWords(from: "the quick brown fox and a lazy dog")
        XCTAssertFalse(words.contains("the"))
        XCTAssertFalse(words.contains("and"))
        XCTAssertFalse(words.contains("a"))
        XCTAssertTrue(words.contains("quick"))
        XCTAssertTrue(words.contains("brown"))
        XCTAssertTrue(words.contains("fox"))
        XCTAssertTrue(words.contains("lazy"))
        XCTAssertTrue(words.contains("dog"))
    }

    func testOverlapCoefficientPerfectSubset() {
        let a: Set<String> = ["apple", "banana"]
        let b: Set<String> = ["apple", "banana", "cherry"]
        // min size = 2, intersection = 2 → 1.0
        XCTAssertEqual(Gita.overlapCoefficient(a, b), 1.0, accuracy: 0.001)
    }

    func testOverlapCoefficientNoOverlap() {
        let a: Set<String> = ["alpha", "beta"]
        let b: Set<String> = ["gamma", "delta"]
        XCTAssertEqual(Gita.overlapCoefficient(a, b), 0.0, accuracy: 0.001)
    }

    func testOverlapCoefficientPartialOverlap() {
        let a: Set<String> = ["a", "b", "c"]
        let b: Set<String> = ["b", "c", "d"]
        // intersection = 2, min = 3 → 2/3 ≈ 0.667
        XCTAssertEqual(Gita.overlapCoefficient(a, b), 2.0 / 3.0, accuracy: 0.001)
    }

    func testOverlapCoefficientEmptyInputsReturnZero() {
        XCTAssertEqual(Gita.overlapCoefficient([], ["x"]), 0.0)
        XCTAssertEqual(Gita.overlapCoefficient(["x"], []), 0.0)
        XCTAssertEqual(Gita.overlapCoefficient([], []),   0.0)
    }
}
