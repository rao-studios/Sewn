//
//  Personalities.swift
//  sewn-server
//
//  Personality management:
//    GET /v1/personalities        (auth)  — list available personas
//    PUT /v1/admin/personalities  (admin) — replace the persona list
//

import Foundation
import Hummingbird

struct PersonalitiesResponse: Codable, ResponseCodable {
    let personalities: [Personality]
}

func registerPersonalitiesRoute(
    _ router: some RouterMethods<SewnRequestContext>,
    _ sewn: Sewn
) {
    router.get("/v1/personalities") { _, _ async throws -> PersonalitiesResponse in
        PersonalitiesResponse(personalities: PersonalityStore.all)
    }
}

func registerAdminPersonalitiesRoute(
    _ router: some RouterMethods<SewnRequestContext>,
    _ sewn: Sewn
) {
    router.put("/v1/admin/personalities") { request, context async throws -> PersonalitiesResponse in
        let body = try await request.decode(as: PersonalitiesResponse.self, context: context)
        guard !body.personalities.isEmpty else {
            throw HTTPError(.badRequest, message: "Provide at least one personality.")
        }
        let ids = body.personalities.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw HTTPError(.badRequest, message: "Personality ids must be unique and non-empty.")
        }
        PersonalityStore.update(body.personalities, logger: context.logger)
        context.logger.info("[Admin] personalities updated — \(ids.joined(separator: ", "))")
        return PersonalitiesResponse(personalities: PersonalityStore.all)
    }
}
