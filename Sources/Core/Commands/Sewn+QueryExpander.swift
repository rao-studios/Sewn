//
//  Sewn+QueryExpander.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/21/26.
//

import Foundation

extension Sewn {

    // MARK: - QueryExpansion

    struct QueryExpansion {
        let original: String
        let variants: [String]

        var all: [String] { [original] + variants }
    }

    // MARK: - expandQuery

    /// Expands a user message with passages from the owner's resonance group.
    /// With Thread-only storage, resonance variants are not available locally — returns original-only.
    nonisolated func expandQuery(
        _ message: String,
        conversationHistory: [[String: Any]],
        request: SewnRequest
    ) -> QueryExpansion {
        logger.debug(
            "Query Expansion",
            "🔭 '\(message.prefix(60))…' → Thread-only mode, no local resonance variants",
            service: .sewn,
            request: request
        )
        return QueryExpansion(original: message, variants: [])
    }

    // MARK: - searchExpanded

    /// Routes the expanded query through Thread fan-out search.
    nonisolated func searchExpanded(
        _ expansion: QueryExpansion,
        request: SewnRequest
    ) async throws -> SearchChatResult {
        if _threadQueryClient != nil {
            return try await searchWithThreads(expansion.original, request: request)
        }
        logger.warning("searchExpanded: no Thread connected — returning empty result", service: .sewn, request: request)
        return SearchChatResult(context: [], adjustments: [], references: [])
    }
}
