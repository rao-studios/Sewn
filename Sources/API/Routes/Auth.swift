//
//  Auth.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//

import Foundation
import Supabase
import Hummingbird

// MARK: - Sign In

func registerAuthSignInRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.post("/v1/auth/sign-in") { request, context async throws -> SignInResponse in
        let body = try await request.decode(as: SignInRequest.self, context: context)
        let logger = context.logger

        let session = try await SupabaseProvider.shared.auth.signIn(
            email: body.email,
            password: body.password
        )

        logger.info("Auth sign-in: user \(session.user.id)")

        return SignInResponse(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresIn: session.expiresIn,
            userId: session.user.id.uuidString
        )
    }
}

// MARK: - Sign Up

func registerAuthSignUpRoute(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    router.post("/v1/auth/sign-up") { request, context async throws -> SignUpResponse in
        let body = try await request.decode(as: SignUpRequest.self, context: context)
        let logger = context.logger

        let response = try await SupabaseProvider.shared.auth.signUp(
            email: body.email,
            password: body.password
        )

        let userId = response.user.id.uuidString.lowercased()
        logger.info("Auth sign-up: user \(userId)")
        seer.gita.initializeWallet(for: userId)

        return SignUpResponse(from: response)
    }
}

// MARK: - Verify OTP

func registerAuthVerifyRoute(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    router.post("/v1/auth/verify") { request, context async throws -> SignUpResponse in
        let body = try await request.decode(as: VerifyRequest.self, context: context)
        let logger = context.logger

        guard let otpType = EmailOTPType(rawValue: body.type) else {
            throw HTTPError(
                .badRequest,
                message: "Invalid OTP type '\(body.type)'. Valid values: \(EmailOTPType.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        let response = try await SupabaseProvider.shared.auth.verifyOTP(
            email: body.email,
            token: body.token,
            type: otpType
        )

        let userId = response.user.id.uuidString.lowercased()
        logger.info("Auth verify (\(body.type)): user \(userId)")
        seer.gita.initializeWallet(for: userId)

        return SignUpResponse(from: response)
    }
}

// MARK: - Refresh Token

func registerAuthRefreshRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.post("/v1/auth/refresh") { request, context async throws -> SignInResponse in
        let body = try await request.decode(as: RefreshRequest.self, context: context)
        let logger = context.logger

        let session = try await SupabaseProvider.shared.auth.refreshSession(
            refreshToken: body.refreshToken
        )

        logger.info("Auth refresh: user \(session.user.id)")

        return SignInResponse(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresIn: session.expiresIn,
            userId: session.user.id.uuidString
        )
    }
}

// MARK: - Sign Out

func registerAuthSignOutRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.post("/v1/auth/sign-out") { request, context async throws -> HTTPResponse.Status in
        let body = try await request.decode(as: SignOutRequest.self, context: context)
        let logger = context.logger

        guard let authHeader = request.headers[.authorization],
              authHeader.hasPrefix("Bearer "),
              !authHeader.dropFirst(7).isEmpty else {
            throw Hummingbird.HTTPError(.unauthorized, message: "Missing Authorization: Bearer token")
        }
        let bearerToken = String(authHeader.dropFirst(7))

        let scope: SignOutScope = {
            switch body.scope {
            case "local":  return .local
            case "others": return .others
            default:       return .global
            }
        }()

        // A fresh client is used here so setting the session does not pollute
        // the shared singleton's session state across concurrent requests.
        let client = try SupabaseProvider.makeClient()
        _ = try await client.auth.setSession(
            accessToken: bearerToken,
            refreshToken: body.refreshToken
        )
        try await client.auth.signOut(scope: scope)

        logger.info("Auth sign-out (scope: \(scope.rawValue))")

        return HTTPResponse.Status.noContent
    }
}

// MARK: - Reset Password

func registerAuthResetPasswordRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.post("/v1/auth/reset-password") { request, context async throws -> HTTPResponse.Status in
        let body = try await request.decode(as: ResetPasswordRequest.self, context: context)
        let logger = context.logger

        try await SupabaseProvider.shared.auth.resetPasswordForEmail(body.email)

        logger.info("Auth reset-password: sent recovery email to \(body.email)")

        return .accepted as HTTPResponse.Status
    }
}
