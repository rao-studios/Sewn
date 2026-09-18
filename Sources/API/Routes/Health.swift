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
    /// Whether the caller holds this server's stack secret — "matched",
    /// "mismatched", or "open" when it asks for none. How Ambient tells its
    /// own server from something else on the port.
    let stack: String
}

func registerHealthRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.get("health") { request, context async throws -> HealthResponse in
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: StackSecret.verdict(of: request.headers[StackSecret.headerName])
        )
    }
}
