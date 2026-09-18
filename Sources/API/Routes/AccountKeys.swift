//
//  AccountKeys.swift
//  sewn-server
//
//  GET /v1/account/keys — the provider keys an account is handed.
//
//  Read from the Supabase `ambient_keys` table with the caller's own JWT, so
//  row-level security decides who may read them (every verified account, per
//  supabase/migrations). Sewn holds no service-role key and adds no rule of
//  its own. A missing table is an empty answer, not an error: the app then
//  falls back to the key its user typed in Settings.
//

import Foundation
import Hummingbird

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AccountKey: Codable {
    let name: String
    let value: String
}

struct AccountKeysResponse: Codable {
    let keys: [AccountKey]
}

func registerAccountKeysRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.get("/v1/account/keys") { request, context async throws -> AccountKeysResponse in
        guard let token = context.authToken else {
            throw HTTPError(.unauthorized, message: "Missing auth token")
        }
        guard
            let supabaseURLString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            let url = URL(string: "\(supabaseURLString)/rest/v1/ambient_keys?select=name,value")
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.executeRequest(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError(.badGateway, message: "Failed to read account keys")
        }
        switch http.statusCode {
        case 200:
            let keys = try JSONDecoder().decode([AccountKey].self, from: data)
                .filter { !$0.name.isEmpty && !$0.value.isEmpty }
            // Names only — a value never reaches the log.
            context.logger.info("Account keys: \(keys.map(\.name).sorted().joined(separator: ", "))")
            return AccountKeysResponse(keys: keys)
        case 404:
            // PostgREST's answer for a table that was never created.
            return AccountKeysResponse(keys: [])
        default:
            throw HTTPError(.badGateway, message: "Failed to read account keys (\(http.statusCode))")
        }
    }
}
