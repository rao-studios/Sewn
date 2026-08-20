//
//  Seer+QueryExpander.swift
//  Seer
//
//  Created by Ritesh Pakala on 3/21/26.
//

import Foundation

extension Seer {

    // MARK: - QueryExpansion

    struct QueryExpansion {
        let original: String
        let variants: [String]

        var all: [String] { [original] + variants }
    }

    // MARK: - expandQuery

    /// Expands a user message with passages from the owner's resonance group.
    /// With Totem-only storage, resonance variants are not available locally — returns original-only.
    nonisolated func expandQuery(
        _ message: String,
        conversationHistory: [[String: Any]],
        request: SeerRequest
    ) -> QueryExpansion {
        logger.debug(
            "Query Expansion",
            "🔭 '\(message.prefix(60))…' → Totem-only mode, no local resonance variants",
            service: .seer,
            request: request
        )
        return QueryExpansion(original: message, variants: [])
    }

    // MARK: - searchExpanded

    /// Routes the expanded query through Totem fan-out search.
    nonisolated func searchExpanded(
        _ expansion: QueryExpansion,
        request: SeerRequest
    ) async throws -> SearchChatResult {
        if _totemQueryClient != nil {
            return try await searchWithTotems(expansion.original, request: request)
        }
        logger.warning("searchExpanded: no Totem connected — returning empty result", service: .seer, request: request)
        return SearchChatResult(context: [], adjustments: [], references: [])
    }
}
