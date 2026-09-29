//
//  RaoVerifiedKeys.swift
//  sewn-server
//
//  WHAT: The Mac's Rao Verified signing key, registered to the signed-in
//        account (POST /v1/account/rao-verified/keys) and listed back (GET).
//        A registered key is how a verifier learns that records sealed by it
//        belong to this account.
//  IN:   context.authToken (AuthMiddleware); SUPABASE_URL and
//        SUPABASE_ANON_KEY from the environment.
//  OUT:  POST → the registered key; GET → {keys: [...]}.
//  PIN:  SEWN CHECKS THE KEY BEFORE SUPABASE SEES IT: a P-256 point, 33 bytes
//        compressed, whose key id is the first 8 bytes of its SHA-256. The
//        register function checks the id again, because a caller holding its
//        own JWT can reach PostgREST without Sewn.
//  PIN:  THE ACCOUNT IS THE CALLER'S. Registration goes through
//        `rao_verified_register_key` with the caller's JWT, which files the
//        key under auth.uid() — never under an id this route sends.
//  PIN:  Bearer-protected by position under AuthMiddleware and never in
//        LocalOnlyGrant: no account, no registration. PostgREST's 404 (the
//        migration not yet run) is a 404 here, which the app reads as "not
//        yet" and asks again later; 401/403 come back as 401 so the app
//        refreshes and retries. The fetch and environment are injectable.
//

import Crypto
import Foundation
import Hummingbird
import RaoStack

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Wire

/// What an app registers.
struct RaoVerifiedKeyRegistration: Codable {
    /// 16 lowercase hex characters: the first 8 bytes of SHA-256(public key).
    let kid: String
    /// P-256, compressed (33 bytes), base64url without padding.
    let publicKey: String
    /// "se" (Secure Enclave) | "kc" (software key in the Keychain).
    let protection: String
    /// "mac" (every Rao app's shared key) | "app" (one app's own).
    let scope: String
    /// The Rao app registering it: "ambient" | "craft" | "veil".
    let app: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case kid, protection, scope, app
        case publicKey = "public_key"
        case appVersion = "app_version"
    }
}

/// One registered key, as Supabase holds it.
struct RaoVerifiedKeyResponse: Codable, Equatable {
    let kid: String
    let publicKey: String
    let protection: String
    let scope: String
    let firstApp: String
    let lastApp: String
    let appVersion: String
    let createdAt: String
    let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case kid, protection, scope
        case publicKey = "public_key"
        case firstApp = "first_app"
        case lastApp = "last_app"
        case appVersion = "app_version"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct RaoVerifiedKeysResponse: Codable {
    let keys: [RaoVerifiedKeyResponse]
}

// MARK: - The key, checked

enum RaoVerifiedKeyCheck {

    /// What is wrong with a registration, or nil when it is a real key
    /// named by its own id.
    static func problem(with registration: RaoVerifiedKeyRegistration) -> String? {
        let hex = Set("0123456789abcdef")
        guard registration.kid.count == 16, registration.kid.allSatisfy(hex.contains) else {
            return "kid must be 16 lowercase hex characters"
        }
        guard let bytes = base64URLDecoded(registration.publicKey), bytes.count == 33,
              (try? P256.Signing.PublicKey(compressedRepresentation: bytes)) != nil
        else {
            return "public_key must be a compressed P-256 key, base64url"
        }
        guard keyID(for: bytes) == registration.kid else {
            return "kid is not this key's id"
        }
        guard ["se", "kc"].contains(registration.protection) else {
            return "protection must be se or kc"
        }
        guard ["mac", "app"].contains(registration.scope) else {
            return "scope must be mac or app"
        }
        guard RaoApp(rawValue: registration.app) != nil else {
            return "app must be one of \(RaoApp.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        guard registration.appVersion.count <= 64 else {
            return "app_version is too long"
        }
        return nil
    }

    static func keyID(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        guard !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Mapping

/// PostgREST's answer → the app's. Pure, so it is tested without a network.
enum RaoVerifiedKeysMapper {

    static func registered(status: Int, data: Data) throws -> RaoVerifiedKeyResponse {
        switch status {
        case 200:
            guard let row = try rows(data).first else {
                throw HTTPError(.badGateway, message: "Key registration sent no row back")
            }
            return row
        default:
            throw failure(status, doing: "register the key")
        }
    }

    static func listed(status: Int, data: Data) throws -> RaoVerifiedKeysResponse {
        switch status {
        case 200: return RaoVerifiedKeysResponse(keys: try rows(data))
        default: throw failure(status, doing: "list the keys")
        }
    }

    private static func rows(_ data: Data) throws -> [RaoVerifiedKeyResponse] {
        do {
            return try JSONDecoder().decode([RaoVerifiedKeyResponse].self, from: data)
        } catch {
            throw HTTPError(.badGateway, message: "Key registration sent an unreadable answer")
        }
    }

    private static func failure(_ status: Int, doing what: String) -> HTTPError {
        switch status {
        case 404:
            // The migration has not run against this Supabase. The app reads
            // this as "not yet", keeps the key, and asks again later.
            return HTTPError(.notFound, message: "Rao Verified key registration is not deployed")
        case 401, 403:
            return HTTPError(.unauthorized, message: "Invalid or expired access token")
        case 400:
            // The register function refused the key after Sewn passed it.
            return HTTPError(.badRequest, message: "Supabase refused the key")
        default:
            return HTTPError(.badGateway, message: "Failed to \(what) (\(status))")
        }
    }
}

// MARK: - Seam

/// The one network call, as the plan route makes it.
typealias RaoVerifiedKeysFetch = AccountPlanFetch

// MARK: - Routes

func registerRaoVerifiedKeysRoutes(
    _ router: some RouterMethods<SewnRequestContext>,
    fetch: @escaping RaoVerifiedKeysFetch = liveAccountPlanFetch,
    environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
) {
    router.post("/v1/account/rao-verified/keys") { request, context async throws -> RaoVerifiedKeyResponse in
        guard let token = context.authToken else {
            throw HTTPError(.unauthorized, message: "Missing auth token")
        }
        let registration = try await request.decode(as: RaoVerifiedKeyRegistration.self, context: context)
        if let problem = RaoVerifiedKeyCheck.problem(with: registration) {
            throw HTTPError(.badRequest, message: problem)
        }
        var urlRequest = try supabaseRequest(
            path: "rest/v1/rpc/rao_verified_register_key", token: token, environment: environment())
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "p_kid": registration.kid,
            "p_public_key": registration.publicKey,
            "p_protection": registration.protection,
            "p_scope": registration.scope,
            "p_app": registration.app,
            "p_app_version": registration.appVersion,
        ], options: [.sortedKeys])

        let (data, status) = try await send(urlRequest, fetch: fetch)
        let key = try RaoVerifiedKeysMapper.registered(status: status, data: data)
        // A key id is public — it names a public key — so it may be logged.
        context.logger.info("Rao Verified key \(key.kid) registered (\(key.scope), \(key.lastApp))")
        return key
    }

    router.get("/v1/account/rao-verified/keys") { _, context async throws -> RaoVerifiedKeysResponse in
        guard let token = context.authToken else {
            throw HTTPError(.unauthorized, message: "Missing auth token")
        }
        var urlRequest = try supabaseRequest(
            path: "rest/v1/rao_verified_keys?select=kid,public_key,protection,scope,first_app,last_app,app_version,created_at,last_seen_at&order=created_at.asc",
            token: token, environment: environment())
        urlRequest.httpMethod = "GET"
        let (data, status) = try await send(urlRequest, fetch: fetch)
        return try RaoVerifiedKeysMapper.listed(status: status, data: data)
    }
}

/// A PostgREST request with the caller's JWT and the anon key.
private func supabaseRequest(
    path: String, token: String, environment env: [String: String]
) throws -> URLRequest {
    guard
        let supabaseURLString = env["SUPABASE_URL"],
        let anonKey = env["SUPABASE_ANON_KEY"],
        let url = URL(string: "\(supabaseURLString)/\(path)")
    else {
        throw HTTPError(.internalServerError, message: "Auth service not configured")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(anonKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
}

private func send(_ request: URLRequest, fetch: RaoVerifiedKeysFetch) async throws -> (Data, Int) {
    do {
        return try await fetch(request)
    } catch {
        throw HTTPError(.badGateway, message: "Key registration unreachable — retry")
    }
}
