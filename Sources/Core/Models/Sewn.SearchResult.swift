//
//  Sewn.SearchResult.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation

extension Sewn {
    // A SearchResult tuned for chat completion requests.
    // Prioritizes the context as Strings for immediate context
    // augmentation in system prompts when processing replies.
    /// Graph provenance for a hybrid search, merged across Thread nodes: which entities
    /// matched the query and how many documents the one-hop expansion pulled in.
    struct GraphTrace {
        var matchedEntityIds: [String] = []
        var expansionEdgeIds: [String] = []
        var expandedDocuments: Int = 0
    }

    struct SearchChatResult {
        var context: [String]
        var adjustments: [SinatraAdjustment]
        var references: [Sewn.DocumentReference]
        var contribution: Gita.Contribution?
        /// Raw partitions retained so span attribution can run after LLM generation.
        var partitions: [Sewn.Partition]
        var trace: Sewn.GraphTrace?
        /// The partitions with their search scores, for the on-device provider's SinatraHarness.
        var retrieved: [Sewn.RetrievedPartition] = []

        init(
            context: [String],
            adjustments: [SinatraAdjustment],
            references: [Sewn.DocumentReference],
            contribution: Gita.Contribution? = nil,
            partitions: [Sewn.Partition] = [],
            trace: Sewn.GraphTrace? = nil,
            retrieved: [Sewn.RetrievedPartition] = []
        ) {
            self.retrieved = retrieved
            self.context = context
            self.adjustments = adjustments
            self.references = references
            self.contribution = contribution
            self.partitions = partitions
            self.trace = trace
        }
    }
}
