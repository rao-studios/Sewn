//
//  Infinite.swift
//  seer-server
//

import Foundation
import Hummingbird

/// Registers all routes under `/v1/infinite`.
func registerInfiniteRoutes(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    registerInfiniteLeaderboardRoute(router, seer)
    registerInfiniteSearchRoute(router, seer)
}

/// `GET /v1/infinite/leaderboard`
///
/// Returns a paginated, ranked list of public groups ordered by a composite
/// activity score (earnings 40%, retrieval count 30%, average sentiment 20%,
/// document count 10%). All metrics are min-max normalised across the full set
/// of public groups at request time — no persistent score is stored.
///
/// Query parameters:
/// - `page`      Int  — 1-indexed page number (default 1)
/// - `page_size` Int  — entries per page, clamped to [1, 100] (default 20)
private func registerInfiniteLeaderboardRoute(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    router.get("/v1/infinite/leaderboard") { request, context async throws -> InfiniteLeaderboardResponse in
        let page     = request.uri.queryParameters.get("page").flatMap(Int.init(_:))      ?? 1
        let pageSize = request.uri.queryParameters.get("page_size").flatMap(Int.init(_:)) ?? 20

        let (entries, total) = await seer.leaderboard(page: page, pageSize: pageSize)

        return InfiniteLeaderboardResponse(
            entries:  entries,
            total:    total,
            page:     max(1, page),
            pageSize: max(1, min(100, pageSize))
        )
    }
}

/// `POST /v1/infinite/search`
///
/// Returns public groups whose `label`, `metadata.description`, or `metadata.tags`
/// contain or match the provided `query` string (case-insensitive). Results are
/// sorted by descending activity score — most active groups first.
///
/// Body: `InfiniteSearchRequest` (query, optional limit, seer identity)
private func registerInfiniteSearchRoute(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    router.post("/v1/infinite/search") { request, context async throws -> InfiniteSearchResponse in
        let searchRequest = try await request.decode(as: InfiniteSearchRequest.self, context: context)
        let limit = searchRequest.limit ?? 20

        context.logger.info(
            "Received infinite-search request: query='\(searchRequest.query)' limit=\(limit)"
        )

        let groups = await seer.searchGroups(query: searchRequest.query, limit: limit)

        return InfiniteSearchResponse(groups: groups, total: groups.count)
    }
}
