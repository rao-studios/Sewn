//
//  MarkerSpanTests.swift
//  seer-serverTests
//
//  Invariants for the citation-marker attribution path: parse/strip round
//  trips, split-marker streaming, exact per-document spans, heuristic
//  fallback merging, and streamed-visible ≡ annotate-visible equivalence.
//

import XCTest
@testable import seer_server

final class MarkerSpanTests: XCTestCase {

    private let sourceIndex: [Int: DocumentID] = [1: "doc-a", 2: "doc-b", 3: "doc-c"]

    // MARK: - parseMarkers

    func test_parse_stripsMarkers_andRecordsDocumentSpans() {
        let text = "You wrote about gauge theory last spring.[[1]] Someone else compared it to music.[[2]] That contrast is worth exploring."
        let result = Gita.parseMarkers(text, sourceIndex: sourceIndex)

        XCTAssertFalse(result.visibleText.contains("[["))
        XCTAssertEqual(result.markerCount, 2)
        XCTAssertEqual(result.documentSpans.count, 2)

        // Spans are offsets into the *stripped* text and cover the marked sentences.
        let visible = Array(result.visibleText)
        for (documentId, spans) in result.documentSpans {
            XCTAssertEqual(spans.count, 1, "\(documentId) should own one sentence")
            let span = spans[0]
            XCTAssertTrue(span.lower >= 0 && span.upper <= visible.count && span.lower < span.upper)
        }
        let sentenceA = String(visible[result.documentSpans["doc-a"]![0].lower..<result.documentSpans["doc-a"]![0].upper])
        XCTAssertTrue(sentenceA.contains("gauge theory"))
        let sentenceB = String(visible[result.documentSpans["doc-b"]![0].lower..<result.documentSpans["doc-b"]![0].upper])
        XCTAssertTrue(sentenceB.contains("compared it to music"))
    }

    func test_parse_markerRuns_attributeSameSentenceToMultipleDocs() {
        let text = "Both notes converge on the same conclusion.[[1]][[3]]"
        let result = Gita.parseMarkers(text, sourceIndex: sourceIndex)

        XCTAssertEqual(result.markerCount, 2)
        XCTAssertEqual(result.documentSpans["doc-a"], result.documentSpans["doc-c"],
                       "a marker run attributes the same sentence to each source")
    }

    func test_parse_unknownIndex_stripsWithoutAttribution() {
        let text = "A bold claim.[[9]]"
        let result = Gita.parseMarkers(text, sourceIndex: sourceIndex)

        XCTAssertEqual(result.visibleText, "A bold claim.")
        XCTAssertEqual(result.markerCount, 1)
        XCTAssertTrue(result.documentSpans.isEmpty)
    }

    func test_parse_noMarkers_returnsTextUntouched() {
        let text = "Nothing to see here. Just prose with [brackets] and numbers [3]."
        let result = Gita.parseMarkers(text, sourceIndex: sourceIndex)

        XCTAssertEqual(result.visibleText, text)
        XCTAssertEqual(result.markerCount, 0)
        XCTAssertTrue(result.documentSpans.isEmpty)
    }

    // MARK: - MarkerStreamFilter

    func test_filter_stripsMarkerSplitAcrossDeltas() {
        var filter = Gita.MarkerStreamFilter()
        var output = ""
        for delta in ["The engine was designed", " in London.[", "[2]", "]", " Neat."] {
            output += filter.feed(delta)
        }
        output += filter.finish()
        XCTAssertEqual(output, "The engine was designed in London. Neat.")
    }

    func test_filter_flushesFalsePositiveTails() {
        var filter = Gita.MarkerStreamFilter()
        var output = ""
        for delta in ["An array literal: [", "[1, 2, 3] is not a marker."] {
            output += filter.feed(delta)
        }
        output += filter.finish()
        XCTAssertEqual(output, "An array literal: [[1, 2, 3] is not a marker.")
    }

    func test_filter_holdsTrailingPartialUntilFinish() {
        var filter = Gita.MarkerStreamFilter()
        var output = filter.feed("Ends with a dangling [[1")
        XCTAssertFalse(output.contains("[[1"), "partial marker must be held back")
        output += filter.finish()
        XCTAssertEqual(output, "Ends with a dangling [[1",
                       "unfinished markers flush verbatim at stream end")
    }

    func test_filter_outputMatchesParseMarkersVisibleText() {
        let raw = "First point.[[1]] Second point spans[[2]] mid-sentence. Trailing [[3]]"
        // Chop into every possible 3-way split to stress boundary handling.
        let characters = Array(raw)
        for i in 1..<(characters.count - 1) {
            for j in (i + 1)..<characters.count {
                var filter = Gita.MarkerStreamFilter()
                var streamed = filter.feed(String(characters[0..<i]))
                streamed += filter.feed(String(characters[i..<j]))
                streamed += filter.feed(String(characters[j...]))
                streamed += filter.finish()
                let expected = Gita.parseMarkers(raw, sourceIndex: sourceIndex).visibleText
                XCTAssertEqual(streamed, expected,
                               "split at (\(i),\(j)) diverged from parseMarkers")
            }
        }
    }

    // MARK: - annotate (exact + heuristic merge)

    private func makeContribution() -> Gita.Contribution {
        Gita.Contribution(owners: [
            Gita.Owner(totemId: "totem-1", ownerId: "alice",
                       documentIds: ["doc-a"], influence: ["doc-a": 0.9], royalty: 0.6),
            Gita.Owner(totemId: "totem-2", ownerId: "bob",
                       documentIds: ["doc-b"], influence: ["doc-b": 0.5], royalty: 0.4),
        ])
    }

    private func makePartitions() -> [Seer.Partition] {
        [
            Seer.Partition(id: "p-a", documentId: "doc-a",
                           url: URL(string: "file:///notes/gauge-theory.txt")!,
                           embedding: [], text: "gauge theory fiber bundles connections curvature",
                           ownerId: "alice"),
            Seer.Partition(id: "p-b", documentId: "doc-b",
                           url: URL(string: "file:///notes/music-analogy.txt")!,
                           embedding: [], text: "music harmony resonance analogy comparison",
                           ownerId: "bob"),
        ]
    }

    func test_annotate_populatesDocumentSpans_andOwnerSpans() {
        let raw = "You explored gauge theory in depth.[[1]] Someone compared the whole thing to music.[[2]]"
        let (visible, contribution) = Gita.annotate(
            responseText: raw,
            contribution: makeContribution(),
            partitions: makePartitions(),
            compactCitations: [],
            sourceIndex: sourceIndex
        )

        XCTAssertFalse(visible.contains("[["))
        let alice = contribution.owners.first { $0.ownerId == "alice" }!
        let bob = contribution.owners.first { $0.ownerId == "bob" }!

        XCTAssertEqual(alice.documentSpans?.keys.sorted(), ["doc-a"])
        XCTAssertEqual(bob.documentSpans?.keys.sorted(), ["doc-b"])
        XCTAssertFalse(alice.spans.isEmpty)
        XCTAssertFalse(bob.spans.isEmpty)

        // Exact spans point at the sentences that carried the markers.
        let visibleChars = Array(visible)
        let aliceText = String(visibleChars[alice.spans[0].lower..<alice.spans[0].upper])
        XCTAssertTrue(aliceText.contains("gauge theory"))
        let bobText = String(visibleChars[bob.spans[0].lower..<bob.spans[0].upper])
        XCTAssertTrue(bobText.contains("music"))
    }

    func test_annotate_noMarkers_fallsBackToHeuristic() {
        // No markers — the heuristic path must still attribute via n-grams.
        let raw = "gauge theory fiber bundles connections curvature all matter here."
        let (visible, contribution) = Gita.annotate(
            responseText: raw,
            contribution: makeContribution(),
            partitions: makePartitions(),
            compactCitations: [Gita.CompactCitation(
                partitionId: "doc-a",
                keyWords: ["gauge", "theory", "fiber", "bundles", "connections"])],
            sourceIndex: sourceIndex
        )
        XCTAssertEqual(visible, raw)
        let alice = contribution.owners.first { $0.ownerId == "alice" }!
        XCTAssertFalse(alice.spans.isEmpty, "heuristic must still find the overlap")
        XCTAssertNil(alice.documentSpans, "no exact attribution without markers")
    }

    func test_annotate_mixedMarkedAndUnmarked_mergesBothPaths() {
        let raw = "You explored gauge theory fiber bundles connections curvature.[[1]] music harmony resonance analogy comparison shows up too."
        let (visible, contribution) = Gita.annotate(
            responseText: raw,
            contribution: makeContribution(),
            partitions: makePartitions(),
            compactCitations: [Gita.CompactCitation(
                partitionId: "doc-b",
                keyWords: ["music", "harmony", "resonance", "analogy", "comparison"])],
            sourceIndex: sourceIndex
        )
        let alice = contribution.owners.first { $0.ownerId == "alice" }!
        let bob = contribution.owners.first { $0.ownerId == "bob" }!
        XCTAssertNotNil(alice.documentSpans, "marked sentence → exact attribution")
        XCTAssertFalse(bob.spans.isEmpty, "unmarked sentence still attributed heuristically")
        // Exact and heuristic spans must not overlap.
        for exact in alice.spans {
            for heuristic in bob.spans {
                XCTAssertFalse(exact.lower < heuristic.upper && heuristic.lower < exact.upper,
                               "exact and heuristic spans overlap in \(visible)")
            }
        }
    }
}
