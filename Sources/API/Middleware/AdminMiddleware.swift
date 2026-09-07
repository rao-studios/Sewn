//
//  AdminMiddleware.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 3/20/26.
//

import Foundation
import Supabase
import Hummingbird

/// Middleware for admin-only routes.
///
/// Performs the same Supabase JWT validation as `AuthMiddleware`, then
/// additionally asserts that the authenticated user is the designated
/// admin account. Returns 403 Forbidden for any other valid user.
struct AdminMiddleware: RouterMiddleware {
    typealias Context = SewnRequestContext

    private static let adminUserId =
        ProcessInfo.processInfo.environment["ADMIN_USER_ID"] ?? ""

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

        guard user.userId.lowercased() == Self.adminUserId.lowercased() else {
            throw Hummingbird.HTTPError(.forbidden, message: "Admin access required")
        }

        var ctx = context
        ctx.authUserId = user.userId
        ctx.authToken = token
        return try await next(request, ctx)
    }
}
