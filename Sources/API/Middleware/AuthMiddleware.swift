//
//  AuthMiddleware.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/23/26.
//

import Foundation
import Supabase
import Hummingbird

// MARK: - Middleware

struct AuthMiddleware: RouterMiddleware {
    typealias Context = SewnRequestContext

    func handle(
        _ request: Request,
        context: SewnRequestContext,
        next: (Request, SewnRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let authHeader = request.headers[.authorization],
              authHeader.hasPrefix("Bearer "),
              !authHeader.dropFirst(7).isEmpty else {
            throw Hummingbird.HTTPError(.unauthorized, message: "Missing Authorization: Bearer token")
        }
        let token = String(authHeader.dropFirst(7))

        let user = try await TokenValidator.validate(token)
        var ctx = context
        ctx.authUserId = user.userId
        ctx.authToken = token
        ctx.authDisplayName = user.displayName
        return try await next(request, ctx)
    }
}
