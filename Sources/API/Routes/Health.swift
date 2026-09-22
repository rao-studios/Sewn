//
//  Health.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/7/26.
//
//  WHAT: GET /health — liveness, and how a launcher tells this Sewn from
//        anything else on the port without ever sending a secret.
//  IN:   X-Ambient-Nonce (the challenge) and, on a shared stack, X-Rao-App
//        (whose secret to prove).
//  OUT:  status/timestamp/stack always; proof, app and contract only when
//        the stack has them (RaoStack's `StackHealthAnswer`).
//  PIN:  An open server's JSON is exactly what it was: nil fields are left
//        out, never sent as null.
//

import Foundation
import Hummingbird
import RaoStack

struct HealthResponse: Codable {
    let status: String
    let timestamp: String
    /// "proof" when this server holds a stack secret it can prove, "open"
    /// when it asks for none. How an app tells its own server from
    /// something else on the port, without ever sending the secret.
    let stack: String
    /// HMAC-SHA256 over the caller's X-Ambient-Nonce, keyed by the secret;
    /// absent unless a well-formed nonce came in and a secret is configured
    /// (on a shared stack: the secret of the app X-Rao-App named).
    let proof: String?
    /// The app the proof is for; absent on an open server and when no proof
    /// could be made on a shared one.
    let app: String?
    /// The shared-stack contract this build speaks; absent on an open server.
    let contract: Int?
}

func registerHealthRoute<Context: RequestContext>(_ router: some RouterMethods<Context>, stack: StackMode) {
    router.get("health") { request, _ async throws -> HealthResponse in
        let answer = stack.healthAnswer(
            nonce: request.headers[.ambientNonce],
            requestedApp: request.headers[.raoApp])
        return HealthResponse(
            status: "healthy",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            stack: answer.stack,
            proof: answer.proof,
            app: answer.app?.rawValue,
            contract: answer.contract
        )
    }
}
