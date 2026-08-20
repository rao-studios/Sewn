//
//  Gita+MarkerSpans.swift
//  seer-server
//
//  Exact contribution tracking from citation markers.
//
//  The chat model is instructed to append invisible `[[n]]` markers to
//  sentences that draw on bracketed source [n] from the compacted context.
//  This file resolves those markers into exact character-offset spans per
//  source document, strips the markers from the user-visible text, and merges
//  with the n-gram heuristic (`Gita.computeSpans`) for unmarked sentences.
//

import Foundation

extension Gita {

    /// Result of parsing a marked response: the user-visible (stripped) text
    /// and exact spans keyed by the source document each marker referenced.
    struct MarkerAnnotation {
        var visibleText: String
        var documentSpans: [DocumentID: [Gita.TextSpan]]
        var markerCount: Int
    }

    // Matches one marker `[[12]]`; runs like `[[1]][[3]]` match repeatedly.
    // (Extended delimiters — bare-slash regex literals aren't enabled in this target.)
    private static let markerPattern = #/\[\[(\d{1,3})\]\]/#

    /// Parses `[[n]]` markers out of `text`. Markers are stripped; each marker
    /// attributes the sentence it terminates (offsets in the *stripped* text)
    /// to `sourceIndex[n]`. Unknown indices strip silently without attribution.
    static func parseMarkers(_ text: String, sourceIndex: [Int: DocumentID]) -> MarkerAnnotation {
        var visible = ""
        visible.reserveCapacity(text.count)
        // (character offset in `visible` where the marker sat, documentId)
        var markers: [(offset: Int, documentId: DocumentID)] = []

        var remaining = Substring(text)
        var visibleCount = 0
        var markerCount = 0
        while let match = remaining.firstMatch(of: markerPattern) {
            let prefix = remaining[remaining.startIndex..<match.range.lowerBound]
            visible += prefix
            visibleCount += prefix.count
            markerCount += 1
            if let index = Int(match.output.1), let documentId = sourceIndex[index] {
                markers.append((visibleCount, documentId))
            }
            remaining = remaining[match.range.upperBound...]
        }
        visible += remaining
        guard markerCount > 0 else {
            return MarkerAnnotation(visibleText: text, documentSpans: [:], markerCount: 0)
        }

        // Resolve each marker to the sentence it terminates in the stripped text.
        let sentences = splitSentences(visible)
        var documentSpans: [DocumentID: [Gita.TextSpan]] = [:]
        for marker in markers {
            // The sentence containing (or ending at) the marker offset: last
            // sentence whose lower bound is before the marker.
            guard let sentence = sentences.last(where: { $0.lower < marker.offset })
                ?? sentences.first else { continue }
            let span = Gita.TextSpan(lower: sentence.lower, upper: sentence.upper)
            documentSpans[marker.documentId, default: []].append(span)
        }
        // Merge duplicate/overlapping spans per document.
        for (documentId, spans) in documentSpans {
            documentSpans[documentId] = mergeSpans(spans)
        }

        return MarkerAnnotation(visibleText: visible, documentSpans: documentSpans,
                                markerCount: markerCount)
    }

    /// Sorts and merges overlapping/adjacent spans.
    static func mergeSpans(_ spans: [Gita.TextSpan]) -> [Gita.TextSpan] {
        let sorted = spans.sorted { ($0.lower, $0.upper) < ($1.lower, $1.upper) }
        var merged: [Gita.TextSpan] = []
        for span in sorted {
            if let last = merged.last, span.lower <= last.upper {
                merged[merged.count - 1] = Gita.TextSpan(lower: last.lower,
                                                         upper: max(last.upper, span.upper))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// The single annotation entry both chat handlers call once the full
    /// response text is available.
    ///
    /// 1. Parses/strips `[[n]]` markers → exact per-document spans.
    /// 2. Graceful fallback: runs the n-gram heuristic (`computeSpans`) over the
    ///    stripped text; heuristic owner spans that overlap an exact span are
    ///    dropped, the rest are kept (unmarked sentences still get attributed).
    /// 3. Maps exact document spans onto owners (`documentId ∈ owner.documentIds`),
    ///    populating both `owner.spans` and `owner.documentSpans`.
    ///
    /// Returns the user-visible text and the annotated contribution.
    static func annotate(
        responseText: String,
        contribution: Gita.Contribution,
        partitions: [Seer.Partition],
        compactCitations: [CompactCitation],
        sourceIndex: [Int: DocumentID]
    ) -> (visibleText: String, contribution: Gita.Contribution) {
        let annotation = parseMarkers(responseText, sourceIndex: sourceIndex)

        // Heuristic pass over the stripped text (also the pre-marker behavior
        // when no markers were emitted).
        let heuristic = computeSpans(
            responseText: annotation.visibleText,
            contribution: contribution,
            partitions: partitions,
            compactCitations: compactCitations
        )
        guard annotation.markerCount > 0, !annotation.documentSpans.isEmpty else {
            return (annotation.visibleText, heuristic)
        }

        let allExactSpans = mergeSpans(annotation.documentSpans.values.flatMap { $0 })

        var result = heuristic
        var owners = Array(result.owners)
        for index in owners.indices {
            var owner = owners[index]
            let ownedDocumentSpans = annotation.documentSpans.filter {
                owner.documentIds.contains($0.key)
            }
            let exactSpans = ownedDocumentSpans.values.flatMap { $0 }

            // Heuristic spans survive only where no exact span overlaps —
            // exact attribution always wins on contested ranges.
            let surviving = owner.spans.filter { span in
                !allExactSpans.contains { $0.lower < span.upper && span.lower < $0.upper }
            }
            owner.spans = mergeSpans(surviving + exactSpans)
            owner.documentSpans = ownedDocumentSpans.isEmpty ? nil : ownedDocumentSpans
            owners[index] = owner
        }
        result = Gita.Contribution(
            owners: Set(owners),
            totalPayout: result.totalPayout,
            serviceCharge: result.serviceCharge,
            totalCost: result.totalCost,
            ledger: result.ledger,
            spenderId: result.spenderId
        )
        return (annotation.visibleText, result)
    }

    // MARK: - Streaming filter

    /// Strips `[[n]]` markers from a streamed token sequence, holding back any
    /// suffix that could be the start of a marker split across deltas. Feed
    /// every delta through `feed`, yield its return value to the client, and
    /// flush with `finish()` when the stream ends. The concatenation of all
    /// outputs equals `parseMarkers(rawText).visibleText`.
    struct MarkerStreamFilter {
        private var held = ""

        /// Longest possible marker `[[999]]` = 7 chars; hold back at most the
        /// last potential-marker prefix.
        private static let maxMarkerLength = 7

        mutating func feed(_ delta: String) -> String {
            var buffer = held + delta
            held = ""

            // Strip complete markers.
            buffer.replace(Gita.markerPattern) { _ in "" }

            // Hold back a trailing partial-marker candidate: the longest suffix
            // that is a strict prefix of a marker pattern.
            if let holdStart = Self.partialMarkerSuffixStart(of: buffer) {
                held = String(buffer[holdStart...])
                buffer = String(buffer[..<holdStart])
            }
            return buffer
        }

        mutating func finish() -> String {
            // Whatever is held at the end was never completed as a marker.
            let tail = held
            held = ""
            return tail
        }

        /// Returns the start index of a trailing substring that could still
        /// become a marker (`[`, `[[`, `[[1`, `[[12`, `[[123`, `[[123]`), or nil.
        static func partialMarkerSuffixStart(of text: String) -> String.Index? {
            // Scan back at most maxMarkerLength characters for a '[' that opens
            // a plausible partial marker.
            var index = text.endIndex
            var scanned = 0
            while index > text.startIndex && scanned < maxMarkerLength {
                index = text.index(before: index)
                scanned += 1
                if text[index] == "[" {
                    let candidate = text[index...]
                    if isPartialMarker(candidate) {
                        // Prefer the outermost '[' of a "[[…" pair.
                        if index > text.startIndex {
                            let previous = text.index(before: index)
                            if text[previous] == "[", isPartialMarker(text[previous...]) {
                                return previous
                            }
                        }
                        return index
                    }
                }
            }
            return nil
        }

        /// True when `candidate` is a strict prefix of a valid marker.
        private static func isPartialMarker(_ candidate: Substring) -> Bool {
            guard candidate.count < maxMarkerLength + 1 else { return false }
            var stage = 0  // 0: '[', 1: '[[', 2: digits, 3: ']'
            var digits = 0
            for (position, character) in candidate.enumerated() {
                switch (position, character) {
                case (0, "["): stage = 1
                case (1, "["): stage = 2
                case (_, _) where stage == 2 && character.isNumber:
                    digits += 1
                    if digits > 3 { return false }
                case (_, "]") where stage == 2 && digits > 0: stage = 3
                case (_, "]") where stage == 3:
                    // Complete marker — not partial (should have been stripped).
                    return false
                default:
                    return false
                }
            }
            return stage >= 1
        }
    }
}
