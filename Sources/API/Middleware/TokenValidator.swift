//
//  TokenValidator.swift
//  sewn-server
//
//  Supabase access-token validation for the request middlewares.
//
//  Validates via a direct GET /auth/v1/user REST call instead of
//  supabase-swift's `auth.user(jwt:)`: the SDK serializes auth operations on a
//  shared client and has been observed to wedge for the full 60s URLSession
//  timeout under concurrent requests — surfacing as a one-minute stall
//  followed by a spurious 401 on every protected route (chat included).
//
//  Successful validations are cached until the token's JWT `exp` (minus a
//  minute of slack), so repeat requests from the same session skip the
//  network round trip entirely.
//

import Foundation
import Hummingbird

enum TokenValidator {
    struct ValidatedUser {
        let userId: String
        let displayName: String?
        let expiresAt: Date
    }

    private static let cache = LockedValue<[String: ValidatedUser]>([:])
    private static let maxCacheEntries = 512

    /// Returns the authenticated user for `token`, from cache when possible.
    /// Throws 401 for rejected tokens, 500 when auth env vars are missing.
    static func validate(_ token: String) async throws -> ValidatedUser {
        if let hit = cache.withLock({ $0[token] }), hit.expiresAt > Date() {
            return hit
        }

        guard
            let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            let url = URL(string: urlString)?
                .appendingPathComponent("auth/v1/user")
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Transport failure — auth state unknown, but the caller can retry;
            // do not hold the request for the default 60s.
            throw HTTPError(.unauthorized, message: "Auth validation unreachable — retry")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = object["id"] as? String
        else {
            throw HTTPError(.unauthorized, message: "Invalid or expired access token")
        }

        let displayName = (object["user_metadata"] as? [String: Any])?["display_name"] as? String
        let validated = ValidatedUser(
            // Match the previous SDK shape (UUID.uuidString is uppercase);
            // Supabase REST returns lowercase ids.
            userId: UUID(uuidString: userId)?.uuidString ?? userId,
            displayName: displayName,
            expiresAt: expiry(of: token)
        )
        cache.withLock {
            if $0.count >= maxCacheEntries {
                let now = Date()
                $0 = $0.filter { $0.value.expiresAt > now }
                if $0.count >= maxCacheEntries { $0.removeAll() }
            }
            $0[token] = validated
        }
        return validated
    }

    /// Drops a token from the cache, so the next request re-asks Supabase.
    /// Sign-out calls this; otherwise a signed-out token keeps passing.
    static func evict(_ token: String) {
        cache.withLock { $0[token] = nil }
    }

    /// The token's `exp` claim minus a minute of slack — safe to trust without
    /// signature verification because it only bounds how long a Supabase-
    /// confirmed token stays cached, never extends a rejected one.
    private static func expiry(of token: String) -> Date {
        let fallback = Date().addingTimeInterval(300)
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return fallback }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? TimeInterval
        else { return fallback }
        return Date(timeIntervalSince1970: exp - 60)
    }
}
