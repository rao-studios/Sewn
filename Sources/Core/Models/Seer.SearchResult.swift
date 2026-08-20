//
//  Seer.SearchResult.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation

extension Seer {
    // A SearchResult tuned for chat completion requests.
    // Prioritizes the context as Strings for immediate context
    // augmentation in system prompts when processing replies.
    /// Graph provenance for a hybrid search, merged across Totem nodes: which entities
    /// matched the query and how many documents the one-hop expansion pulled in.
    struct GraphTrace {
        var matchedEntityIds: [String] = []
        var expansionEdgeIds: [String] = []
        var expandedDocuments: Int = 0
    }

    struct SearchChatResult {
        var context: [String]
        var adjustments: [SinatraAdjustment]
        var references: [Seer.DocumentReference]
        var contribution: Gita.Contribution?
        /// Raw partitions retained so span attribution can run after LLM generation.
        var partitions: [Seer.Partition]
        var trace: Seer.GraphTrace?

        init(
            context: [String],
            adjustments: [SinatraAdjustment],
            references: [Seer.DocumentReference],
            contribution: Gita.Contribution? = nil,
            partitions: [Seer.Partition] = [],
            trace: Seer.GraphTrace? = nil
        ) {
            self.context = context
            self.adjustments = adjustments
            self.references = references
            self.contribution = contribution
            self.partitions = partitions
            self.trace = trace
        }
    }
}
