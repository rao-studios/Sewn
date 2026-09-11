//
//  Health.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/7/26.
//

import Foundation
import Hummingbird

struct HealthResponse: Codable {
    let status: String
    let timestamp: String
}

func registerHealthRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.get("health") { request, context async throws -> HealthResponse in
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
