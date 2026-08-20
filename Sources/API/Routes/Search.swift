//
//  Search.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Hummingbird

func registerSearchRoute(
    _ router: some RouterMethods<SeerRequestContext>,
    _ seer: Seer,
    modelProvider: ModelProvider
) {
    router.post("/v1/search") { request, context async throws -> SearchResponse in
        let searchRequest = try await request.decode(as: SearchRequest.self, context: context)
        let logger = context.logger
        let searchReqId = "search-\(UUID().uuidString)"

        logger.info("Received search request (ID: \(searchReqId)) for model: \(searchRequest.model ?? "Default")")

        let result = try await seer.search(
            searchRequest.query,
            request: try searchRequest.seer.from(context),
            enableSinatraPark: searchRequest.train
        )
        
        return .init(
            texts: result.context,
            references: result.references,
            contribution: result.contribution,
            graph: result.trace.map {
                SearchResponseGraph(
                    matchedEntityIds: $0.matchedEntityIds,
                    expansionEdgeIds: $0.expansionEdgeIds,
                    expandedDocuments: $0.expandedDocuments
                )
            }
        )
    }
}
