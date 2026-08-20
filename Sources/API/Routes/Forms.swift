import Foundation
import Hummingbird

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

struct FeedbackRequest: Codable {
    let message: String
    let rating: Int?
    let category: String?
}

struct FeedbackResponse: Codable {
    let success: Bool
    let userId: String

    enum CodingKeys: String, CodingKey {
        case success
        case userId = "user_id"
    }
}

// MARK: - Internal helpers

private struct _FeedbackRow: Codable {
    let user_id: String
    let message: String
    let rating: Int?
    let category: String?
}

// MARK: - Route

/// Registers POST /v1/feedback — inserts user feedback into the Supabase `feedback` table.
/// The authenticated user's ID is used as the submitter key.
func registerFeedbackRoute(_ router: some RouterMethods<SeerRequestContext>) {
    router.post("/v1/feedback") { request, context async throws -> FeedbackResponse in
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

        let body = try await request.decode(as: FeedbackRequest.self, context: context)

        let row = _FeedbackRow(
            user_id: userId,
            message: body.message,
            rating: body.rating,
            category: body.category
        )

        guard let url = URL(string: "\(supabaseURLString)/rest/v1/feedback") else {
            throw HTTPError(.internalServerError, message: "Invalid Supabase URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        urlRequest.httpBody = try JSONEncoder().encode(row)

        let (_, response) = try await URLSession.shared.executeRequest(urlRequest)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 201 || http.statusCode == 200 else {
            throw HTTPError(.badGateway, message: "Failed to submit feedback")
        }

        return FeedbackResponse(success: true, userId: userId)
    }
}
