//
//  EmbeddingsResponse.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/21/25.
//

import Hummingbird

/// Result of a single embedding handle operation.
enum EmbeddingHandleResult {
    /// A new document was ingested and queued for Thread indexing.
    case embedded(
        documentId: String,
        texts: [String],
        tags: [String],
        promptTokens: Int
    )
    /// The document existed and a new owner was linked — no embedding work needed.
    case linked(documentId: String)
    /// The document already exists and this owner is already linked — no-op.
    case skipped
}
