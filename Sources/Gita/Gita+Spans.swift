//
//  Gita+Spans.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 3/29/26.
//

import Foundation

// Patent #4 (extension): Contribution Span Attribution
// Maps each Gita.Owner's retrieved partitions to contiguous character-offset
// ranges inside the completed LLM response, producing highlight metadata
// that the client can render without any additional network round-trips.
//
// Algorithm (mirrors ContributionSpanGenerator on the client):
//  1. Split the response into sentences, group into ContentChunks (≥minContentWords).
//  2. Rank owners by peak influence. For each owner's partitions (ranked by influence),
//     find the best unclaimed chunk via overlap-coefficient on content-word sets.
//  3. Merge adjacent claimed chunks per owner into contiguous TextSpan values.

extension Gita {
    /// Per-partition citation extracted from the compact summary.
    /// Key phrases are the ordered content words from compact-summary sentences that explicitly
    /// reference this partition — they are closer to the phrasing the response LLM actually saw
    /// than the raw partition text, making them the most reliable span seed.
    struct CompactCitation {
        let partitionId: String
        /// Ordered content words from compact-summary sentences that cite this partition.
        let keyWords: [String]
    }

    /// Parse a compact summary to build per-partition citation key-word lists.
    ///
    /// The compact prompt instructs the LLM to reference sources by their quoted title
    /// (e.g. `"startup-notes"`). This function finds every sentence in the compact output that
    /// contains a known source name and attaches its content words to the matching partition.
    /// No additional LLM call is needed — this is a deterministic post-processing step.
    static func extractCitations(
        from compactText: String,
        partitions: [Sewn.Partition],
        requestOwnerId: String
    ) -> [CompactCitation] {
        guard !partitions.isEmpty, !compactText.isEmpty else { return [] }

        // Split compact text into personal (outside <external>) and external (inside <external>) pools.
        let (personalText, externalText) = splitExternalBlock(compactText)
        let personalSentences = splitSentences(personalText)
        let externalSentences = splitSentences(externalText)

        let normalizedOwnerId = requestOwnerId.lowercased()

        var wordsByPartition: [String: [String]] = [:]

        for partition in partitions {
            let sourceName = normalise(partition.url.deletingPathExtension().lastPathComponent)
            guard !sourceName.isEmpty else { continue }

            // Route to the correct sentence pool based on ownership.
            let sentences = partition.ownerId == normalizedOwnerId ? personalSentences : externalSentences

            for sentence in sentences {
                let normSentence = normalise(sentence.text)
                guard normSentence.contains(sourceName) else { continue }
                let words = contentWords(from: normSentence)
                wordsByPartition[partition.documentId, default: []].append(contentsOf: words)
            }
        }

        return wordsByPartition.map { CompactCitation(partitionId: $0.key, keyWords: $0.value) }
    }

    /// Splits `text` around the first `<external>…</external>` block.
    /// Returns `(outside, inside)` — both are empty strings when the tag is absent.
    private static func splitExternalBlock(_ text: String) -> (personal: String, external: String) {
        let openTag  = "<external>"
        let closeTag = "</external>"
        guard let openRange  = text.range(of: openTag),
              let closeRange = text.range(of: closeTag),
              openRange.upperBound <= closeRange.lowerBound
        else {
            return (text, "")
        }
        let before   = String(text[text.startIndex..<openRange.lowerBound])
        let inside   = String(text[openRange.upperBound..<closeRange.lowerBound])
        let after    = String(text[closeRange.upperBound...])
        return (before + after, inside)
    }

    /// Compute response-text highlight spans for every owner in `contribution`.
    ///
    /// - Parameters:
    ///   - responseText: The fully generated LLM response string.
    ///   - contribution: Royalty contribution built from the retrieved partitions.
    ///   - partitions: The partitions that were retrieved and injected as context.
    ///   - compactCitations: Per-partition key-word lists extracted from the compact summary.
    ///     When provided, span detection runs a deterministic citation-phrase step first.
    /// - Returns: A new `Gita.Contribution` with `spans` populated on each owner.
    static func computeSpans(
        responseText: String,
        contribution: Gita.Contribution,
        partitions: [Sewn.Partition],
        compactCitations: [CompactCitation] = []
    ) -> Gita.Contribution {
        guard !contribution.owners.isEmpty, !responseText.isEmpty else {
            return contribution
        }

        let sentences = splitSentences(responseText)
        guard !sentences.isEmpty else { return contribution }

        let chunks = buildChunks(from: sentences, in: responseText)
        var claimedSentenceIndices = IndexSet()

        // Build a fast lookup: partitionId → compact citation key words.
        let citationMap: [String: [String]] = Dictionary(
            compactCitations.map { ($0.partitionId, $0.keyWords) },
            uniquingKeysWith: { first, _ in first }
        )

        let ranked = contribution.owners.sorted {
            ($0.influence.values.max() ?? 0) > ($1.influence.values.max() ?? 0)
        }

        var spansByOwner: [String: [Gita.TextSpan]] = [:]

        for owner in ranked {
            let ownerPartitions = partitions
                .filter { owner.documentIds.contains($0.documentId) }
                .sorted {
                    (owner.influence[$0.documentId] ?? 0) > (owner.influence[$1.documentId] ?? 0)
                }

            var matchedChunks: [ContentChunk] = []
            for partition in ownerPartitions {
                let compactWords = citationMap[partition.documentId] ?? []
                guard let chunk = bestChunk(
                    nodeText: partition.text,
                    compactWords: compactWords,
                    chunks: chunks,
                    claimedSentenceIndices: claimedSentenceIndices
                ) else { continue }

                chunk.sentenceIndices.forEach { claimedSentenceIndices.insert($0) }
                matchedChunks.append(chunk)
            }

            spansByOwner[owner.identityKey] = mergeAdjacentChunks(matchedChunks)
        }

        let annotatedOwners = Set(contribution.owners.map { owner -> Gita.Owner in
            var o = owner
            o.spans = spansByOwner[owner.identityKey] ?? []
            return o
        })

        return Gita.Contribution(owners: annotatedOwners)
    }

    // MARK: - Content Chunks

    private struct ContentChunk {
        let sentenceIndices: [Int]
        /// Character offsets into the original response string.
        let lower: Int
        let upper: Int
        /// Unordered content-word set — used for bag-of-words overlap (similarity fallback).
        let features: Set<String>
        /// Ordered content words — used for n-gram phrase matching (direct match).
        let normalizedWords: [String]
    }

    private static let minContentWords = 5

    private static func buildChunks(
        from sentences: [(text: String, lower: Int, upper: Int)],
        in _: String
    ) -> [ContentChunk] {
        var chunks: [ContentChunk] = []
        var i = 0
        while i < sentences.count {
            var indices = [i]
            var combined = sentences[i].text
            var upper = sentences[i].upper

            while contentWords(from: normalise(stripMarkdown(combined))).count < minContentWords
                && i + indices.count < sentences.count
            {
                let next = sentences[i + indices.count]
                combined += " " + next.text
                upper = next.upper
                indices.append(i + indices.count)
            }

            let words = contentWords(from: normalise(stripMarkdown(combined)))
            chunks.append(ContentChunk(
                sentenceIndices: indices,
                lower: sentences[i].lower,
                upper: upper,
                features: Set(words),
                normalizedWords: words
            ))
            i += indices.count
        }
        return chunks
    }

    // MARK: - Similarity

    /// Minimum n-gram size for phrase matching at all levels.
    private static let phraseNgramSize = 3
    /// Compact-citation match threshold — highest bar, these words come from the
    /// LLM-summarised form the response model actually read.
    private static let compactMatchThreshold: Double = 0.25
    /// Raw-partition direct phrase match threshold.
    private static let directMatchThreshold: Double = 0.20
    /// Bag-of-words similarity floor — used only when neither phrase-match pass fires.
    private static let similarityThreshold: Double = 0.15

    /// Returns all sliding windows of `n` consecutive words joined by spaces.
    /// If `words.count < n` returns an empty array so callers fall through to the next step.
    private static func ngrams(from words: [String], n: Int) -> [String] {
        guard words.count >= n else { return [] }
        return (0...(words.count - n)).map { i in
            words[i..<(i + n)].joined(separator: " ")
        }
    }

    /// Find the best unclaimed chunk for a retrieved partition.
    ///
    /// Strategy (in priority order):
    /// 0. **Compact citation match** — n-gram overlap against key words extracted from the
    ///    compact summary sentences that explicitly cited this partition. These phrases are the
    ///    distilled form the response LLM actually read, so matches here are the most reliable.
    /// 1. **Direct phrase match** — n-gram overlap against raw partition content words.
    ///    Catches verbatim or near-verbatim reuse of the retrieved text in the response.
    /// 2. **Bag-of-words similarity fallback** — unordered overlap coefficient, used when the
    ///    LLM paraphrases content significantly.
    private static func bestChunk(
        nodeText: String,
        compactWords: [String],
        chunks: [ContentChunk],
        claimedSentenceIndices: IndexSet
    ) -> ContentChunk? {
        let nodeWords = contentWords(from: normalise(stripMarkdown(nodeText)))
        guard !nodeWords.isEmpty else { return nil }

        let compactNgrams = Set(ngrams(from: compactWords, n: phraseNgramSize))
        let nodeNgrams    = Set(ngrams(from: nodeWords,    n: phraseNgramSize))
        let nodeFeatures  = Set(nodeWords)

        var bestCompactScore: Double = 0
        var bestCompactChunk: ContentChunk? = nil
        var bestDirectScore: Double = 0
        var bestDirectChunk: ContentChunk? = nil
        var bestSimScore: Double = 0
        var bestSimChunk: ContentChunk? = nil

        for chunk in chunks {
            guard !chunk.sentenceIndices.contains(where: { claimedSentenceIndices.contains($0) })
            else { continue }

            let chunkNgrams = Set(ngrams(from: chunk.normalizedWords, n: phraseNgramSize))

            // 0. Compact citation phrase match.
            if !compactNgrams.isEmpty {
                let score = overlapCoefficient(compactNgrams, chunkNgrams)
                if score > bestCompactScore {
                    bestCompactScore = score
                    bestCompactChunk = chunk
                }
            }

            // 1. Direct raw-partition phrase match.
            if !nodeNgrams.isEmpty {
                let score = overlapCoefficient(nodeNgrams, chunkNgrams)
                if score > bestDirectScore {
                    bestDirectScore = score
                    bestDirectChunk = chunk
                }
            }

            // 2. Bag-of-words similarity (always computed; used as last resort).
            let simScore = overlapCoefficient(nodeFeatures, chunk.features)
            if simScore > bestSimScore {
                bestSimScore = simScore
                bestSimChunk = chunk
            }
        }

        if bestCompactScore >= compactMatchThreshold, let c = bestCompactChunk { return c }
        if bestDirectScore  >= directMatchThreshold,  let c = bestDirectChunk  { return c }
        guard bestSimScore  >= similarityThreshold else { return nil }
        return bestSimChunk
    }

    private static func mergeAdjacentChunks(_ chunks: [ContentChunk]) -> [Gita.TextSpan] {
        guard !chunks.isEmpty else { return [] }

        let sorted = chunks.sorted { ($0.sentenceIndices.first ?? 0) < ($1.sentenceIndices.first ?? 0) }
        var result: [Gita.TextSpan] = []
        var currentLower = sorted[0].lower
        var currentUpper = sorted[0].upper
        var currentMaxIdx = sorted[0].sentenceIndices.max() ?? 0

        for chunk in sorted.dropFirst() {
            let nextMinIdx = chunk.sentenceIndices.min() ?? 0
            if nextMinIdx <= currentMaxIdx + 1 {
                currentUpper = max(currentUpper, chunk.upper)
                currentMaxIdx = max(currentMaxIdx, chunk.sentenceIndices.max() ?? 0)
            } else {
                result.append(Gita.TextSpan(lower: currentLower, upper: currentUpper))
                currentLower = chunk.lower
                currentUpper = chunk.upper
                currentMaxIdx = chunk.sentenceIndices.max() ?? 0
            }
        }
        result.append(Gita.TextSpan(lower: currentLower, upper: currentUpper))
        return result
    }

    // MARK: - Sentence Splitting

    /// Returns `(sentence text, lower char offset, upper char offset)` tuples.
    static func splitSentences(
        _ text: String
    ) -> [(text: String, lower: Int, upper: Int)] {
        var result: [(text: String, lower: Int, upper: Int)] = []
        var segmentStart = text.startIndex
        var cursor = text.startIndex

        func flush(to breakEnd: String.Index) {
            let sentenceText = String(text[segmentStart..<breakEnd])
            let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let lower = text.distance(from: text.startIndex, to: segmentStart)
                let upper = text.distance(from: text.startIndex, to: breakEnd)
                result.append((sentenceText, lower, upper))
            }
            segmentStart = breakEnd
        }

        while cursor < text.endIndex {
            let ch = text[cursor]
            let next = text.index(after: cursor)

            if (ch == "." || ch == "!" || ch == "?"),
               next < text.endIndex,
               text[next] == " " || text[next] == "\n"
            {
                let breakEnd = text.index(after: next)
                flush(to: breakEnd)
                cursor = segmentStart
                continue
            }

            if ch == "\n", next < text.endIndex, text[next] == "\n" {
                let breakEnd = text.index(after: next)
                flush(to: breakEnd)
                cursor = segmentStart
                continue
            }

            cursor = next
        }

        if segmentStart < text.endIndex {
            let sentenceText = String(text[segmentStart...])
            if !sentenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lower = text.distance(from: text.startIndex, to: segmentStart)
                let upper = text.count
                result.append((sentenceText, lower, upper))
            }
        }

        return result
    }

    // MARK: - Markdown Stripping

    static func stripMarkdown(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`]+`", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*{1,3}|_{1,3}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^>\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^[\\-\\*\\+]\\s+|^\\d+\\.\\s+", with: "", options: .regularExpression)
        return s
    }

    // MARK: - Text Helpers

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .punctuationCharacters).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "in", "on", "at", "to",
        "for", "of", "with", "by", "from", "is", "are", "was", "were", "be",
        "been", "being", "have", "has", "had", "do", "does", "did", "will",
        "would", "could", "should", "may", "might", "shall", "can", "that",
        "this", "these", "those", "it", "its", "as", "not", "no", "so", "yet",
        "both", "than", "then", "when", "where", "who", "which", "what", "how",
        "all", "each", "every", "any", "some", "their", "they", "them", "there",
        "we", "us", "our", "you", "your", "he", "she", "his", "her", "him",
        "i", "me", "my", "into", "about", "over", "also", "more", "very",
        "just", "like", "up", "out", "even", "back", "after", "through",
        "between", "much", "well", "most", "other", "while", "since", "within",
        "such", "only", "one", "two", "three", "because", "though", "here",
        "whether", "s", "t", "re", "ve", "ll", "d"
    ]

    static func contentWords(from normalisedText: String) -> [String] {
        normalisedText.split(separator: " ")
            .map(String.init)
            .filter { w in
                w.count > 1 &&
                !stopWords.contains(w) &&
                !w.allSatisfy(\.isNumber)
            }
    }

    static func overlapCoefficient(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let minSize = Double(min(a.count, b.count))
        guard minSize > 0 else { return 0 }
        return Double(a.intersection(b).count) / minSize
    }
}
