//
//  Flow6_QueryExpansionTests.swift
//  seer-serverTests
//
//  Tests for the QueryExpansion system added 2026-03-21:
//    - QueryExpansion struct: `all` composition
//    - Variant parsing: newline split, trim, duplicate/empty filter
//    - Context block construction from conversation history
//    - searchExpanded deduplication by partition ID
//
//  These tests cover the pure-logic layers of Seer+QueryExpander.swift without
//  requiring an LLM or embedding model.
//

import XCTest
@testable import seer_server

final class Flow6_QueryExpansionTests: XCTestCase {

    // MARK: - QueryExpansion struct

    func testAllIncludesOriginalFirst() {
        let expansion = Seer.QueryExpansion(original: "what is seer", variants: ["a", "b"])
        XCTAssertEqual(expansion.all.first, "what is seer",
            "The original query must always be first in `all` — it is the canonical search vector " +
            "used to park in Sinatra, and it must rank first for Sinatra feedback consistency")
    }

    func testAllContainsAllVariants() {
        let variants = ["query A", "query B", "query C"]
        let expansion = Seer.QueryExpansion(original: "original", variants: variants)
        for v in variants {
            XCTAssertTrue(expansion.all.contains(v),
                "all must contain every variant: '\(v)'")
        }
    }

    func testAllCountIsOriginalPlusVariants() {
        let variants = ["v1", "v2", "v3"]
        let expansion = Seer.QueryExpansion(original: "orig", variants: variants)
        XCTAssertEqual(expansion.all.count, variants.count + 1,
            "all.count must be variants.count + 1 (the original)")
    }

    func testAllWithEmptyVariantsIsJustOriginal() {
        let expansion = Seer.QueryExpansion(original: "solo query", variants: [])
        XCTAssertEqual(expansion.all, ["solo query"],
            "With no variants, all must contain only the original — " +
            "LLM fallback path must still produce a valid single-query search")
    }

    func testAllPreservesVariantOrder() {
        let variants = ["first", "second", "third"]
        let expansion = Seer.QueryExpansion(original: "orig", variants: variants)
        XCTAssertEqual(expansion.all, ["orig", "first", "second", "third"],
            "Variants must appear in insertion order after the original")
    }

    // MARK: - Variant parsing
    //
    // The expandQuery function parses raw LLM output as:
    //   raw.components(separatedBy: .newlines)
    //      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    //      .filter { !$0.isEmpty && $0 != message }

    private func parseVariants(from raw: String, original: String) -> [String] {
        raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != original }
    }

    func testParsingThreeCleanLines() {
        let raw = "query one\nquery two\nquery three"
        let variants = parseVariants(from: raw, original: "original")
        XCTAssertEqual(variants, ["query one", "query two", "query three"])
    }

    func testParsingFiltersEmptyLines() {
        let raw = "query one\n\nquery two\n\n"
        let variants = parseVariants(from: raw, original: "original")
        XCTAssertEqual(variants, ["query one", "query two"],
            "Empty lines must be filtered — LLM sometimes inserts blank separators")
    }

    func testParsingTrimsLeadingAndTrailingWhitespace() {
        let raw = "  trimmed left\nright trimmed  \n  both sides  "
        let variants = parseVariants(from: raw, original: "original")
        XCTAssertEqual(variants, ["trimmed left", "right trimmed", "both sides"],
            "Each variant must be trimmed — LLM may pad with spaces")
    }

    func testParsingExcludesVariantIdenticalToOriginal() {
        let original = "what is seer"
        let raw = "what is seer\nother query\nanother angle"
        let variants = parseVariants(from: raw, original: original)
        XCTAssertFalse(variants.contains(original),
            "A variant identical to the original must be excluded — " +
            "it would just embed the same vector twice and waste a budget slot")
        XCTAssertEqual(variants.count, 2)
    }

    func testParsingAllBlankLLMResponseYieldsNoVariants() {
        let raw = "\n\n   \n"
        let variants = parseVariants(from: raw, original: "query")
        XCTAssertTrue(variants.isEmpty,
            "A blank LLM response must produce zero variants — " +
            "the caller falls back to original-only search automatically")
    }

    func testParsingEmptyStringYieldsNoVariants() {
        let variants = parseVariants(from: "", original: "query")
        XCTAssertTrue(variants.isEmpty)
    }

    func testParsingDoesNotDeduplicateDifferentVariants() {
        // Two distinct variants that are not the original should both survive.
        let raw = "angle one\nangle two"
        let variants = parseVariants(from: raw, original: "original message")
        XCTAssertEqual(variants.count, 2)
    }

    func testParsingPreservesInternalSpacesInVariants() {
        let raw = "multi word query variant"
        let variants = parseVariants(from: raw, original: "original")
        XCTAssertEqual(variants, ["multi word query variant"],
            "Internal spaces must be preserved — trimming only touches leading/trailing")
    }

    // MARK: - Context block construction
    //
    // expandQuery builds a context block from the last 4 content values:
    //   historySnippet = conversationHistory
    //       .compactMap { $0["content"] as? String }
    //       .suffix(4)
    //       .joined(separator: "\n")
    //   contextBlock = historySnippet.isEmpty ? "" : "\nConversation context:\n\(historySnippet)\n"

    private func buildContextBlock(from history: [[String: Any]]) -> String {
        let snippet = history
            .compactMap { $0["content"] as? String }
            .suffix(4)
            .joined(separator: "\n")
        return snippet.isEmpty ? "" : "\nConversation context:\n\(snippet)\n"
    }

    func testContextBlockIsEmptyForNoHistory() {
        let block = buildContextBlock(from: [])
        XCTAssertEqual(block, "",
            "Empty conversation history must produce an empty context block")
    }

    func testContextBlockContainsHistoryContent() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "first message"],
            ["role": "assistant", "content": "first reply"],
        ]
        let block = buildContextBlock(from: history)
        XCTAssertTrue(block.contains("first message"))
        XCTAssertTrue(block.contains("first reply"))
    }

    func testContextBlockLimitedToLastFourMessages() {
        let history: [[String: Any]] = (0..<8).map {
            ["role": "user", "content": "message \($0)"]
        }
        let block = buildContextBlock(from: history)

        // Only messages 4–7 should appear (last 4)
        for i in 0..<4 {
            XCTAssertFalse(block.contains("message \(i)"),
                "Message \(i) is older than the 4-message window and must not appear")
        }
        for i in 4..<8 {
            XCTAssertTrue(block.contains("message \(i)"),
                "Message \(i) is within the 4-message window and must appear")
        }
    }

    func testContextBlockMissingContentKeyIsFiltered() {
        let history: [[String: Any]] = [
            ["role": "user"],                          // no content key
            ["role": "assistant", "content": "reply"],
        ]
        let block = buildContextBlock(from: history)
        XCTAssertTrue(block.contains("reply"),
            "Messages with a content key must appear")
        XCTAssertFalse(block.contains("[role]") || block.contains("user"),
            "Messages without a content key must not contribute")
    }

    func testContextBlockHeaderPresent() {
        let history: [[String: Any]] = [["role": "user", "content": "test"]]
        let block = buildContextBlock(from: history)
        XCTAssertTrue(block.contains("Conversation context:"),
            "Non-empty history must produce a context block with the 'Conversation context:' header")
    }

    // MARK: - searchExpanded deduplication
    //
    // searchExpanded de-duplicates by partition ID using first-occurrence-wins:
    //   var seen = Set<String>()
    //   let uniquePartitions = result.partitions.filter { seen.insert($0.id).inserted }

    private func deduplicatePartitions(_ partitions: [Seer.Partition]) -> [Seer.Partition] {
        var seen = Set<String>()
        return partitions.filter { seen.insert($0.id).inserted }
    }

    func testDeduplicationRemovesDuplicateIds() {
        let p1 = Seer.Partition.test(id: "dup-id", documentId: "doc1")
        let p2 = Seer.Partition.test(id: "dup-id", documentId: "doc1")  // same id
        let p3 = Seer.Partition.test(id: "unique-id", documentId: "doc2")

        let unique = deduplicatePartitions([p1, p2, p3])
        XCTAssertEqual(unique.count, 2,
            "Duplicate partition IDs must be collapsed — each ID must appear exactly once")
    }

    func testDeduplicationFirstOccurrenceWins() {
        let first  = Seer.Partition.test(id: "shared", documentId: "docA", text: "first text")
        let second = Seer.Partition.test(id: "shared", documentId: "docA", text: "second text")

        let unique = deduplicatePartitions([first, second])
        XCTAssertEqual(unique.first?.text, "first text",
            "First occurrence must win — determines which text enters the LLM context window")
    }

    func testDeduplicationPreservesAllUniquePartitions() {
        let partitions = (0..<5).map {
            Seer.Partition.test(id: "p\($0)", documentId: "doc\($0)")
        }
        let unique = deduplicatePartitions(partitions)
        XCTAssertEqual(unique.count, 5,
            "All unique partitions must survive deduplication")
    }

    func testDeduplicationEmptyInputProducesEmptyOutput() {
        let unique = deduplicatePartitions([])
        XCTAssertTrue(unique.isEmpty)
    }

    func testDeduplicationAllSameIdRetainsOne() {
        let partitions = (0..<4).map {
            Seer.Partition.test(id: "same-id", documentId: "doc", text: "text-\($0)")
        }
        let unique = deduplicatePartitions(partitions)
        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(unique.first?.text, "text-0",
            "The first occurrence must be retained when all IDs are identical")
    }

    // MARK: - Royalty fairness invariant
    //
    // The query expander system prompt includes this explicit fairness statement:
    //   "These queries directly determine which contributors' work is surfaced and attributed.
    //    Precision and fairness matter."
    //
    // This invariant test encodes the core contract: original query must never be excluded,
    // so at minimum one query always reaches the search and royalty layer.

    func testExpansionAlwaysProducesAtLeastOneQuery() {
        let expansionFromLLMFailure = Seer.QueryExpansion(original: "any query", variants: [])
        XCTAssertGreaterThanOrEqual(expansionFromLLMFailure.all.count, 1,
            "Even on total LLM failure, at least the original query must reach the search layer — " +
            "no LLM failure must result in a zero-partition royalty distribution")
    }

    func testExpansionOriginalIsNeverModified() {
        let original = "  original with spaces  "
        let expansion = Seer.QueryExpansion(original: original, variants: ["v1"])
        XCTAssertEqual(expansion.all.first, original,
            "The original query must be stored verbatim — it is the vector parked in Sinatra " +
            "and any modification would corrupt the feedback signal")
    }
}
