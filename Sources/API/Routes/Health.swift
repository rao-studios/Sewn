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
    /// "proof" when this server holds a stack secret it can prove, "open"
    /// when it asks for none. How Ambient tells its own server from
    /// something else on the port, without ever sending the secret.
    let stack: String
    /// HMAC-SHA256 over the caller's X-Ambient-Nonce, keyed by the secret;
    /// absent unless a well-formed nonce came in and a secret is configured.
    let proof: String?
}

func registerHealthRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.get("health") { request, context async throws -> HealthResponse in
        let answer = StackSecret.healthAnswer(nonce: request.headers[StackSecret.nonceHeaderName])
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: answer.stack,
            proof: answer.proof
        )
    }
}
