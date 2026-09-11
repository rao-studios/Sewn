//
//  SentenceBoundaryTests.swift
//  sewn-serverTests
//

import XCTest
@testable import sewn_server

final class SentenceBoundaryTests: XCTestCase {

    // MARK: - textEndsSentence: positive cases

    func testEndsPeriod() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Hello world."))
    }

    func testEndsExclamation() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Watch out!"))
    }

    func testEndsQuestion() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Are you sure?"))
    }

    func testEndsEllipsis() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("She waited\u{2026}"))
    }

    func testEndsDoubleExclamation() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("No way\u{203C}"))
    }

    func testEndsExclamationQuestion() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Really\u{2049}"))
    }

    func testEndsIdeographicStop() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("終わり\u{3002}"))
    }

    func testEndsDevanagariDanda() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("समाप्त\u{0964}"))
    }

    func testEndsFullwidthPeriod() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("完成\u{FF0E}"))
    }

    func testEndsFullwidthExclamation() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("好\u{FF01}"))
    }

    func testEndsFullwidthQuestion() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("なぜ\u{FF1F}"))
    }

    // Terminator + closing punctuation
    func testEndsPeriodCurlyDoubleQuote() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("He said \u{201C}hello.\u{201D}"))
    }

    func testEndsExclamationCurlyQuote() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Wow!\u{2019}"))
    }

    func testEndsPeriodClosingParen() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("(See note.)"))
    }

    func testEndsPeriodClosingBracket() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Defined in §3.]"))
    }

    // Trailing whitespace should be ignored
    func testIgnoresTrailingWhitespace() {
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Done.   "))
        XCTAssertTrue(SentenceBoundary.textEndsSentence("Done!\n"))
    }

    // MARK: - textEndsSentence: negative cases

    func testMidSentenceWord() {
        XCTAssertFalse(SentenceBoundary.textEndsSentence("The quick brown fox"))
    }

    func testEndsComma() {
        XCTAssertFalse(SentenceBoundary.textEndsSentence("However, the result,"))
    }

    func testEndsColon() {
        XCTAssertFalse(SentenceBoundary.textEndsSentence("The following items:"))
    }

    func testEndsSemicolon() {
        XCTAssertFalse(SentenceBoundary.textEndsSentence("First item; second"))
    }

    func testEmptyString() {
        XCTAssertFalse(SentenceBoundary.textEndsSentence(""))
    }

    func testOnlyWhitespace() {
        XCTAssertFalse(SentenceBoundary.textEndsSentence("   "))
    }

    // MARK: - completions(for:)

    func testSingleChunkReturnsAllNils() {
        let texts = ["Only one chunk without terminator"]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0])
    }

    func testCompleteChunkGetsNilCompletion() {
        let texts = [
            "This is a complete sentence.",
            "Another complete sentence."
        ]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertNil(result[0], "Complete sentence should not receive a completion")
        XCTAssertNil(result[1], "Last chunk always nil")
    }

    func testIncompleteChunkGetsFullNextChunk() {
        // The entire next chunk is stored — no sentence extraction.
        let texts = [
            "The storm was getting worse and the ship",
            "could not turn back. The crew was afraid."
        ]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertEqual(result[0], texts[1])
        XCTAssertNil(result[1])
    }

    func testLastChunkAlwaysNil() {
        let texts = [
            "Incomplete chunk without ending",
            "Also incomplete"
        ]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertNil(result[1], "Last chunk never gets a completion regardless of content")
    }

    func testNoCascading() {
        // Each chunk borrows from the original texts array — not from an already-extended chunk.
        let texts = [
            "The first chunk ends mid",
            "sentence here. And then more without ending",
            "which continues. Final sentence."
        ]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertEqual(result[0], texts[1])
        XCTAssertEqual(result[1], texts[2])
        XCTAssertNil(result[2])
    }

    func testMixedCompleteAndIncomplete() {
        let texts = [
            "Alice went to the store.",             // complete → nil
            "She was looking for something she",    // incomplete → full next chunk
            "had lost last week. It was gone.",     // complete → nil
        ]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertNil(result[0])
        XCTAssertEqual(result[1], texts[2])
        XCTAssertNil(result[2])
    }

    func testNextChunkWithNoTerminatorStillStored() {
        // Even if the next chunk has no sentence boundary itself, it is still
        // stored whole — the client gets everything available.
        let texts = [
            "She was looking for the",
            "missing piece of the"
        ]
        let result = SentenceBoundary.completions(for: texts)
        XCTAssertEqual(result[0], texts[1])
    }

    // MARK: - upToFirstSentence

    func testUpToFirstSentenceExclamation() {
        XCTAssertEqual(SentenceBoundary.upToFirstSentence("It worked! Now we can proceed."), "It worked!")
    }

    func testUpToFirstSentenceQuestion() {
        XCTAssertEqual(SentenceBoundary.upToFirstSentence("Was it finished? Nobody knew."), "Was it finished?")
    }

    func testUpToFirstSentencePeriod() {
        XCTAssertEqual(SentenceBoundary.upToFirstSentence("He arrived early. The meeting had not started."), "He arrived early.")
    }

    func testUpToFirstSentenceDecimalNotSplit() {
        XCTAssertEqual(SentenceBoundary.upToFirstSentence("The value is 3.14 kg. That is precise."), "The value is 3.14 kg.")
    }

    func testUpToFirstSentenceNoBoundaryReturnsAll() {
        // No boundary found — return the full string rather than nothing.
        let s = "continued without any terminator"
        XCTAssertEqual(SentenceBoundary.upToFirstSentence(s), s)
    }

}
