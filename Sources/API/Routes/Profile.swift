import Foundation
import Hummingbird

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Internal helpers

private struct _ProfileRow: Codable {
    let id: String
    let display_name: String?
}

// MARK: - Routes

/// Registers GET /v1/profile — returns the authenticated user's profile, or another
/// user's profile when `?userId=<id>` is supplied.
///
/// Cross-user lookup reads from the public `profiles` table via PostgREST using the
/// requesting user's JWT — no service role key required.
func registerProfileRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.get("/v1/profile") { request, context async throws -> SeerProfile in
        guard let requestingUserId = context.authUserId else {
            throw HTTPError(.unauthorized, message: "Missing authenticated user ID")
        }

        // If no userId query param, return the requester's own profile (fast path).
        guard let targetUserId = request.uri.queryParameters.get("userId"),
              !targetUserId.isEmpty else {
            return SeerProfile(userId: requestingUserId, displayName: context.authDisplayName)
        }

        // Same user — no table lookup needed.
        if targetUserId == requestingUserId {
            return SeerProfile(userId: requestingUserId, displayName: context.authDisplayName)
        }

        // Cross-user lookup via the public profiles table (PostgREST, anon key + user JWT).
        guard
            let supabaseURLString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            let token = context.authToken
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }

        guard let url = URL(string: "\(supabaseURLString)/rest/v1/profiles?id=eq.\(targetUserId)&select=id,display_name") else {
            throw HTTPError(.internalServerError, message: "Invalid Supabase URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.executeRequest(urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(.notFound, message: "User not found")
        }

        let rows = try JSONDecoder().decode([_ProfileRow].self, from: data)
        guard let profile = rows.first else {
            throw HTTPError(.notFound, message: "User not found")
        }

        return SeerProfile(userId: profile.id, displayName: profile.display_name)
    }
}

/// Registers PATCH /v1/profile — updates the authenticated user's display name in Supabase.
func registerUpdateProfileRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.patch("/v1/profile") { request, context async throws -> SeerProfile in
        guard let userId = context.authUserId else {
            throw HTTPError(.unauthorized, message: "Missing authenticated user ID")
        }
        guard let token = context.authToken else {
            throw HTTPError(.unauthorized, message: "Missing auth token")
        }
        guard
            let supabaseURLString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }

        let body = try await request.decode(as: UpdateProfileRequest.self, context: context)

        guard let url = URL(string: "\(supabaseURLString)/auth/v1/user") else {
            throw HTTPError(.internalServerError, message: "Invalid Supabase URL")
        }

        let payload = ["data": ["display_name": body.displayName]]
        let payloadData = try JSONEncoder().encode(payload)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = payloadData

        let (_, response) = try await URLSession.shared.executeRequest(urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(.badGateway, message: "Failed to update profile in Supabase")
        }

        return SeerProfile(userId: userId, displayName: body.displayName)
    }
}

// MARK: - URLSession helper

extension URLSession {
    func executeRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { cont in
            dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), response!))
            }.resume()
        }
        #else
        return try await data(for: request)
        #endif
    }
}
