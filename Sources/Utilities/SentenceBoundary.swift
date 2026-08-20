//
//  SentenceBoundary.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 4/11/26.
//

import Foundation

enum SentenceBoundary {

    // MARK: - Character sets

    /// Characters that close a quotation or grouping and may appear immediately
    /// after a sentence terminator (e.g. `."` or `)'`).
    static let closingPunctuation: Set<Character> = [
        "\"", "'",
        "\u{2018}", "\u{2019}",  // ' '  (curly single quotes)
        "\u{201C}", "\u{201D}",  // " "  (curly double quotes)
        "\u{00BB}", "\u{203A}",  // » ›  (angle quotes)
        ")", "]", "}"
    ]

    /// Punctuation marks that unambiguously end a sentence.
    /// A plain period (`.`) is handled separately because it also appears in
    /// abbreviations ("Dr.") and decimals ("3.14").
    static let unambiguousTerminators: Set<Character> = [
        "!", "?",
        "\u{2026}",              // … (horizontal ellipsis)
        "\u{203C}",              // ‼  (double exclamation)
        "\u{2049}",              // ⁉  (exclamation question)
        "\u{FF01}",              // ！ (fullwidth exclamation)
        "\u{FF1F}",              // ？ (fullwidth question mark)
        "\u{0964}",              // ।  (Devanagari danda)
        "\u{0965}",              // ॥  (Devanagari double danda)
        "\u{3002}",              // 。 (ideographic full stop)
        "\u{FE12}",              // ︒ (presentation form ideographic full stop)
    ]

    /// All sentence terminators, including the ambiguous period.
    static let allTerminators: Set<Character> = unambiguousTerminators.union(
        [".", "\u{FE52}", "\u{FF0E}"]  // . ﹒ ．
    )

    // MARK: - Public API

    /// Returns `true` when `text` ends on a complete sentence boundary.
    ///
    /// The check is multi-layered:
    /// 1. Strip trailing whitespace.
    /// 2. Skip one optional closing-punctuation character.
    /// 3. Test whether the last character is a recognised sentence terminator.
    ///
    /// No language model is used, so the result is purely structural.
    static func textEndsSentence(_ text: String) -> Bool {
        guard let lastNonSpace = text.lastIndex(where: { !$0.isWhitespace }) else { return false }
        var idx = lastNonSpace

        if closingPunctuation.contains(text[idx]) {
            guard idx > text.startIndex else { return false }
            idx = text.index(before: idx)
        }

        return allTerminators.contains(text[idx])
    }

    /// Returns `text` up to and including the first sentence boundary.
    ///
    /// Used by `Seer.Partition.fullText` to trim the stored next-chunk completion
    /// to just its first sentence for display. If no boundary is found the full
    /// string is returned so the caller always gets something meaningful.
    ///
    /// Period (`.`) is accepted as a boundary only when followed by whitespace
    /// then an uppercase letter, or at the very end of the string, to avoid
    /// splitting on abbreviations and decimals.
    static func upToFirstSentence(_ text: String) -> String {
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]

            if unambiguousTerminators.contains(ch) {
                var end = text.index(after: i)
                if end < text.endIndex, closingPunctuation.contains(text[end]) {
                    end = text.index(after: end)
                }
                return String(text[text.startIndex..<end])
            }

            if ch == "." || ch == "\u{FE52}" || ch == "\u{FF0E}" {
                let afterDot = text.index(after: i)
                if afterDot == text.endIndex {
                    return String(text[text.startIndex...i])
                }
                if text[afterDot].isWhitespace {
                    let afterSpace = text.index(after: afterDot)
                    if afterSpace == text.endIndex || text[afterSpace].isUppercase {
                        return String(text[text.startIndex..<afterDot])
                    }
                }
            }

            i = text.index(after: i)
        }

        return text  // no boundary found — return everything
    }

    /// Computes `completionText` values parallel to `texts`.
    ///
    /// For each chunk that does not end on a sentence boundary, the entire
    /// following chunk is stored verbatim as the completion. This guarantees
    /// the concatenation `text + completionText` always contains the full
    /// continuation — no sentence-boundary heuristic is applied here, so
    /// there is no risk of the completion itself being cut off mid-sentence.
    ///
    /// The last element is always `nil` (no following chunk to borrow from).
    static func completions(for texts: [String]) -> [String?] {
        guard texts.count > 1 else { return Array(repeating: nil, count: texts.count) }
        var result: [String?] = Array(repeating: nil, count: texts.count)
        for i in 0..<(texts.count - 1) {
            guard !textEndsSentence(texts[i]) else { continue }
            result[i] = texts[i + 1]
        }
        return result
    }
}
