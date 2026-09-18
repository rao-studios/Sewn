//
//  Auth.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//

import Foundation
import Supabase
import Hummingbird

// MARK: - Sign In

func registerAuthSignInRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.post("/v1/auth/sign-in") { request, context async throws -> SignInResponse in
        let body = try await request.decode(as: SignInRequest.self, context: context)
        let logger = context.logger

        let session = try await mappingAuthErrors {
            try await SupabaseProvider.shared.auth.signIn(
                email: body.email,
                password: body.password
            )
        }

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

func registerAuthSignUpRoute(_ router: some RouterMethods<SewnRequestContext>, _ sewn: Sewn) {
    router.post("/v1/auth/sign-up") { request, context async throws -> SignUpResponse in
        let body = try await request.decode(as: SignUpRequest.self, context: context)
        let logger = context.logger

        let response = try await mappingAuthErrors {
            try await SupabaseProvider.shared.auth.signUp(
                email: body.email,
                password: body.password
            )
        }

        let userId = response.user.id.uuidString.lowercased()
        logger.info("Auth sign-up: user \(userId)")
        sewn.gita.initializeWallet(for: userId)

        return SignUpResponse(from: response)
    }
}

// MARK: - Verify OTP

func registerAuthVerifyRoute(_ router: some RouterMethods<SewnRequestContext>, _ sewn: Sewn) {
    router.post("/v1/auth/verify") { request, context async throws -> SignUpResponse in
        let body = try await request.decode(as: VerifyRequest.self, context: context)
        let logger = context.logger

        guard let otpType = EmailOTPType(rawValue: body.type) else {
            throw HTTPError(
                .badRequest,
                message: "Invalid OTP type '\(body.type)'. Valid values: \(EmailOTPType.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        let response = try await mappingAuthErrors {
            try await SupabaseProvider.shared.auth.verifyOTP(
                email: body.email,
                token: body.token,
                type: otpType
            )
        }

        let userId = response.user.id.uuidString.lowercased()
        logger.info("Auth verify (\(body.type)): user \(userId)")
        sewn.gita.initializeWallet(for: userId)

        return SignUpResponse(from: response)
    }
}

// MARK: - Refresh Token

func registerAuthRefreshRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.post("/v1/auth/refresh") { request, context async throws -> SignInResponse in
        let body = try await request.decode(as: RefreshRequest.self, context: context)
        let logger = context.logger

        let session = try await mappingAuthErrors {
            try await SupabaseProvider.shared.auth.refreshSession(
                refreshToken: body.refreshToken
            )
        }

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

func registerAuthSignOutRoute(_ router: some RouterMethods<SewnRequestContext>) {
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

        // Forget the validation now, whatever Supabase says next: a cached
        // token would otherwise keep passing AuthMiddleware until its exp.
        TokenValidator.evict(bearerToken)

        // A fresh client is used here so setting the session does not pollute
        // the shared singleton's session state across concurrent requests.
        let client = try SupabaseProvider.makeClient()
        try await mappingAuthErrors {
            _ = try await client.auth.setSession(
                accessToken: bearerToken,
                refreshToken: body.refreshToken
            )
            try await client.auth.signOut(scope: scope)
        }

        logger.info("Auth sign-out (scope: \(scope.rawValue))")

        return HTTPResponse.Status.noContent
    }
}

// MARK: - Reset Password

func registerAuthResetPasswordRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.post("/v1/auth/reset-password") { request, context async throws -> HTTPResponse.Status in
        let body = try await request.decode(as: ResetPasswordRequest.self, context: context)
        let logger = context.logger

        try await mappingAuthErrors {
            try await SupabaseProvider.shared.auth.resetPasswordForEmail(body.email)
        }

        logger.info("Auth reset-password: sent recovery email to \(body.email)")

        return .accepted as HTTPResponse.Status
    }
}

// MARK: - Resend Code

/// Sends the emailed code again. `signup` re-sends the confirmation;
/// `recovery` requests a fresh reset code, which is how GoTrue re-sends one.
func registerAuthResendRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.post("/v1/auth/resend") { request, context async throws -> HTTPResponse.Status in
        let body = try await request.decode(as: ResendRequest.self, context: context)

        try await mappingAuthErrors {
            switch body.type {
            case "signup":
                try await SupabaseProvider.shared.auth.resend(email: body.email, type: .signup)
            case "recovery":
                try await SupabaseProvider.shared.auth.resetPasswordForEmail(body.email)
            default:
                throw HTTPError(.badRequest, message: "Invalid code type '\(body.type)'. Valid values: signup, recovery")
            }
        }

        context.logger.info("Auth resend (\(body.type))")
        return .accepted as HTTPResponse.Status
    }
}

// MARK: - Update Password

/// Sets a new password for the signed-in user — the last step of a reset,
/// after the recovery code has produced a session.
func registerAuthUpdatePasswordRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.post("/v1/auth/update-password") { request, context async throws -> HTTPResponse.Status in
        guard let token = context.authToken else {
            throw HTTPError(.unauthorized, message: "Missing auth token")
        }
        guard
            let supabaseURLString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            let url = URL(string: "\(supabaseURLString)/auth/v1/user")
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }

        let body = try await request.decode(as: UpdatePasswordRequest.self, context: context)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(["password": body.password])

        let (data, response) = try await URLSession.shared.executeRequest(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(.badGateway, message: "Failed to update password")
        }
        guard http.statusCode == 200 else {
            // GoTrue's own sentence ("Password should be at least 6 characters.")
            // is the one worth showing; its 4xx status is kept.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["msg"] as? String ?? $0["message"] as? String }
            let status = HTTPResponse.Status(code: http.statusCode)
            throw HTTPError(
                (400..<500).contains(http.statusCode) ? status : .badGateway,
                message: message ?? "Failed to update password")
        }

        context.logger.info("Auth update-password: user \(context.authUserId ?? "?")")
        return .noContent as HTTPResponse.Status
    }
}

// MARK: - Errors

/// Runs a Supabase auth call with its failures translated for the client.
func mappingAuthErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch {
        throw authHTTPError(error)
    }
}

/// A Supabase auth failure as the client should see it. Unmapped, every one
/// reaches the app as a bare 500, and a wrong password reads like a crash.
func authHTTPError(_ error: Error) -> Error {
    guard let auth = error as? AuthError else { return error }
    switch auth.errorCode {
    case .invalidCredentials:
        return HTTPError(.unauthorized, message: "Wrong email or password.")
    case .emailNotConfirmed:
        return HTTPError(.forbidden, message: "Confirm your email first.")
    case .otpExpired:
        return HTTPError(.unauthorized, message: "That code has expired or is wrong.")
    case .weakPassword, .validationFailed:
        return HTTPError(.unprocessableContent, message: auth.message)
    case .samePassword:
        return HTTPError(.unprocessableContent, message: "Choose a password you haven't used before.")
    case .userAlreadyExists, .emailExists:
        return HTTPError(.conflict, message: "An account with that email already exists.")
    case .signupDisabled:
        return HTTPError(.forbidden, message: "Sign-ups are closed right now.")
    case .overRequestRateLimit, .overEmailSendRateLimit:
        return HTTPError(.tooManyRequests, message: "Too many attempts. Wait a minute and try again.")
    case .refreshTokenNotFound, .refreshTokenAlreadyUsed, .sessionNotFound, .sessionExpired,
         .badJWT, .invalidJWT:
        return HTTPError(.unauthorized, message: "Your session has ended. Sign in again.")
    default:
        // Anything else still carries GoTrue's status and its own sentence.
        if case let .api(message, _, _, response) = auth, (400..<500).contains(response.statusCode) {
            return HTTPError(HTTPResponse.Status(code: response.statusCode), message: message)
        }
        return HTTPError(.badGateway, message: auth.message)
    }
}
