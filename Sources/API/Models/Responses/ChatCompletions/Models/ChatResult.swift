//
//  ChatResult.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation

struct ChatResult {
    let input: UserInput
    let references: [Sewn.DocumentReference]
    /// Raw partitions retained so span attribution can run after LLM generation.
    let partitions: [Sewn.Partition]
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
    ///   2. Persist `result.documentStatsUpdates` to `SewnRegistry` via
    ///      `sewn.accumulatePerformance(_:)`.
    /// Returns `nil` when Sinatra was not invoked (e.g. VLM path).
    let sinatraTask: Task<Sinatra.PrepareResult?, any Error>?
    /// The retrieved partitions with scores, for the on-device provider's SinatraMLX.
    let retrieved: [Sewn.RetrievedPartition]
    /// When the user's message arrived: the client's timestamp, else receipt time.
    let userMessageAt: Date

    init(
        input: UserInput,
        references: [Sewn.DocumentReference],
        partitions: [Sewn.Partition] = [],
        compactCitations: [Gita.CompactCitation] = [],
        sourceIndex: [Int: DocumentID] = [:],
        personality: Personality? = nil,
        contribution: Gita.Contribution? = nil,
        tone: SinatraTone? = nil,
        autoMemory: Bool = false,
        sinatraTask: Task<Sinatra.PrepareResult?, any Error>? = nil,
        retrieved: [Sewn.RetrievedPartition] = [],
        userMessageAt: Date = Date()
    ) {
        self.retrieved = retrieved
        self.userMessageAt = userMessageAt
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
