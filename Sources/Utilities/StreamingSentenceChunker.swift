//
//  StreamingSentenceChunker.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 7/22/26.
//

import Foundation

/// Accumulates streamed text deltas and emits TTS-ready chunks of complete
/// sentences. The first chunk is a single sentence so audio starts as early
/// as possible; later chunks batch `sentencesPerChunk` sentences (emitting
/// early once `maxWordsPerChunk` is reached) so synthesis requests stay
/// efficient without adding head-of-line latency.
///
/// Boundary detection rides `SentenceBoundary`. A sentence is only considered
/// complete when its terminator is strictly *inside* the buffer — a terminator
/// at the buffer's end may still be followed by closing punctuation (`."`) or
/// be an abbreviation, so it is held until the next delta or `flushRemainder`.
struct StreamingSentenceChunker {
    var firstChunkSentences = 1
    var sentencesPerChunk = 2
    var maxWordsPerChunk = 30

    private var buffer = ""
    private var pendingSentences: [String] = []
    private var emittedFirstChunk = false

    /// Feed one streamed delta; returns zero or more chunks ready for TTS.
    mutating func feed(_ delta: String) -> [String] {
        buffer += delta
        extractCompleteSentences()
        return drainReadyChunks(force: false)
    }

    /// Flush whatever remains (a trailing partial sentence and any batched
    /// sentences that never reached a full chunk). Returns `nil` when empty.
    mutating func flushRemainder() -> String? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !tail.isEmpty { pendingSentences.append(tail) }
        let chunks = drainReadyChunks(force: true)
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: " ")
    }

    // MARK: - Internals

    private mutating func extractCompleteSentences() {
        while true {
            let candidate = SentenceBoundary.upToFirstSentence(buffer)
            // `upToFirstSentence` returns the whole string when no boundary is
            // found; equal length also covers a terminator at the very end,
            // which stays held until more text arrives.
            guard candidate.count < buffer.count else { return }
            let sentence = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer.dropFirst(candidate.count))
            if !sentence.isEmpty {
                pendingSentences.append(sentence)
            }
        }
    }

    private mutating func drainReadyChunks(force: Bool) -> [String] {
        var chunks: [String] = []
        while !pendingSentences.isEmpty {
            let targetSentences = emittedFirstChunk ? sentencesPerChunk : firstChunkSentences
            var take = 0
            var words = 0
            while take < pendingSentences.count && take < targetSentences && words < maxWordsPerChunk {
                words += pendingSentences[take].split(whereSeparator: \.isWhitespace).count
                take += 1
            }
            let complete = take == targetSentences || words >= maxWordsPerChunk
            guard complete || force else { break }
            chunks.append(pendingSentences.prefix(take).joined(separator: " "))
            pendingSentences.removeFirst(take)
            emittedFirstChunk = true
        }
        return chunks
    }
}

/// Markdown arrives in the visible token stream but must not be spoken.
/// Mirrors the client-side speaker's sanitizer in miniature: emphasis and
/// code markers dropped, links reduced to their text, headings unwrapped.
enum TTSTextSanitizer {
    static func sanitize(_ text: String) -> String {
        var s = text
        for pattern in [
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),   // [text](url) → text
            ("`{1,3}([^`]*)`{1,3}", "$1"),          // inline/backtick code
            ("\\*{1,3}([^*]+)\\*{1,3}", "$1"),      // *emphasis*
            ("_{1,3}([^_]+)_{1,3}", "$1"),          // _emphasis_
            ("^#{1,6}\\s+", ""),                    // headings
            ("^\\s*[-*+]\\s+", ""),                 // list bullets
        ] {
            s = s.replacingOccurrences(
                of: pattern.0, with: pattern.1,
                options: [.regularExpression], range: nil
            )
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
