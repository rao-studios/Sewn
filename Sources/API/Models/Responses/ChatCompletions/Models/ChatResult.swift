//
//  ChatResult.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation

struct ChatResult {
    let input: UserInput
    let references: [Seer.DocumentReference]
    /// Raw partitions retained so span attribution can run after LLM generation.
    let partitions: [Seer.Partition]
    /// Per-partition citation key words from the compact summary, used as the
    /// highest-confidence seed in `Gita.computeSpans`.
    let compactCitations: [Gita.CompactCitation]
    /// Bracket-tag number → source document id (the `[n]` tags the model may
    /// cite as `[[n]]` markers). Resolves markers to exact document spans.
    let sourceIndex: [Int: DocumentID]
    /// The resolved personality serving this chat, when one was requested.
    let personality: Personality?
    let contribution: Gita.Contribution?
    let tone: SinatraTone?
    let autoMemory: Bool
    /// Task running Sinatra's sentiment analysis concurrently with the primary
    /// LLM generation. Await this after the primary generation completes to:
    ///   1. Merge `result.ledger` into the main `TokenLedger` before pricing.
    ///   2. Persist `result.documentStatsUpdates` to `SeerRegistry` via
    ///      `seer.accumulatePerformance(_:)`.
    /// Returns `nil` when Sinatra was not invoked (e.g. VLM path).
    let sinatraTask: Task<Sinatra.PrepareResult?, any Error>?

    init(
        input: UserInput,
        references: [Seer.DocumentReference],
        partitions: [Seer.Partition] = [],
        compactCitations: [Gita.CompactCitation] = [],
        sourceIndex: [Int: DocumentID] = [:],
        personality: Personality? = nil,
        contribution: Gita.Contribution? = nil,
        tone: SinatraTone? = nil,
        autoMemory: Bool = false,
        sinatraTask: Task<Sinatra.PrepareResult?, any Error>? = nil
    ) {
        self.input = input
        self.references = references
        self.partitions = partitions
        self.compactCitations = compactCitations
        self.sourceIndex = sourceIndex
        self.personality = personality
        self.contribution = contribution
        self.tone = tone
        self.autoMemory = autoMemory
        self.sinatraTask = sinatraTask
    }
}
