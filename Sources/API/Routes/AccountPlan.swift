//
//  AccountPlan.swift
//  sewn-server
//
//  WHAT: GET /v1/account/plan — whether the signed-in account has Ambient
//        Plus. Read from the Supabase `ambient_my_plan` RPC with the caller's
//        own JWT; `ambient_is_plus(uid)` is the one rule, and Sewn forwards
//        its answer without adding a rule of its own.
//  IN:   context.authToken (AuthMiddleware); SUPABASE_URL and
//        SUPABASE_ANON_KEY from the environment.
//  OUT:  {known, plan: "plus"|"free", is_plus, status, price_id, interval,
//        current_period_start, current_period_end, cancel_at_period_end,
//        trial_end}, dates as PostgREST sent them. `known: false` when the
//        RPC is not deployed (PostgREST 404): free, but nobody has said so.
//  PIN:  Bearer-protected by position under AuthMiddleware and never in
//        LocalOnlyGrant — no account, no plan. PostgREST's 401/403 come back
//        as 401 so the app's refresh-and-retry fires; a transport failure is
//        a 502 the app may retry, never a "free" that would cost a paying
//        account its key. `stripe_customer_id` and `livemode` never leave
//        Sewn, and the log carries the plan word and status only — no ids.
//        The fetch and the environment are injectable so the tests never
//        reach Supabase.
//

import Foundation
import Hummingbird

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Wire

struct AccountPlanResponse: Codable {
    /// False when Sewn could not learn the plan (the RPC is not deployed);
    /// every other field is then the free default.
    let known: Bool
    /// "plus" | "free" — the word the app switches on.
    let plan: String
    let isPlus: Bool
    /// Stripe's status word, unchecked: trialing | active | past_due | canceled | …
    let status: String?
    let priceId: String?
    /// "month" | "year"
    let interval: String?
    let currentPeriodStart: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool
    let trialEnd: String?

    enum CodingKeys: String, CodingKey {
        case known, plan, status, interval
        case isPlus = "is_plus"
        case priceId = "price_id"
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case trialEnd = "trial_end"
    }

    /// The RPC was not there to ask.
    static let unknown = AccountPlanResponse(
        known: false, plan: "free", isPlus: false, status: nil, priceId: nil, interval: nil,
        currentPeriodStart: nil, currentPeriodEnd: nil, cancelAtPeriodEnd: false, trialEnd: nil)

    /// Asked and answered: no subscription row at all.
    static let free = AccountPlanResponse(
        known: true, plan: "free", isPlus: false, status: nil, priceId: nil, interval: nil,
        currentPeriodStart: nil, currentPeriodEnd: nil, cancelAtPeriodEnd: false, trialEnd: nil)
}

/// One row of `ambient_my_plan()`. The row also carries `stripe_customer_id`
/// and `livemode`; they are left undeclared here so they are never forwarded.
private struct AccountPlanRow: Decodable {
    /// The one bit that matters — required, so a row that lost it is an
    /// error rather than a silent "free".
    let isPlus: Bool
    let status: String?
    let priceId: String?
    let interval: String?
    let currentPeriodStart: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool?
    let trialEnd: String?

    enum CodingKeys: String, CodingKey {
        case status, interval
        case isPlus = "is_plus"
        case priceId = "price_id"
        case currentPeriodStart = "current_period_start"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case trialEnd = "trial_end"
    }
}

// MARK: - Mapping

/// PostgREST's answer → the app's. Pure, so it is tested without a network.
enum AccountPlanMapper {
    static func response(status: Int, data: Data) throws -> AccountPlanResponse {
        switch status {
        case 200:
            let rows: [AccountPlanRow]
            do {
                rows = try JSONDecoder().decode([AccountPlanRow].self, from: data)
            } catch {
                throw HTTPError(.badGateway, message: "Plan service sent an unreadable answer")
            }
            guard let row = rows.first else { return .free }
            return AccountPlanResponse(
                known: true,
                plan: row.isPlus ? "plus" : "free",
                isPlus: row.isPlus,
                status: row.status,
                priceId: row.priceId,
                interval: row.interval,
                currentPeriodStart: row.currentPeriodStart,
                currentPeriodEnd: row.currentPeriodEnd,
                cancelAtPeriodEnd: row.cancelAtPeriodEnd ?? false,
                trialEnd: row.trialEnd)
        case 404:
            // PostgREST's answer for an RPC that was never created: the
            // migration has not run against this Supabase. Not an error —
            // the app shows free and says Sewn could not tell.
            return .unknown
        case 401, 403:
            // The JWT is expired or rejected. 401 so Ambient refreshes and
            // retries once, exactly as it does on every other route.
            throw HTTPError(.unauthorized, message: "Invalid or expired access token")
        default:
            throw HTTPError(.badGateway, message: "Failed to read the plan (\(status))")
        }
    }
}

// MARK: - Seams

/// The one network call: the request out, the body and HTTP status back.
typealias AccountPlanFetch = @Sendable (URLRequest) async throws -> (Data, Int)

/// URLSession in production.
let liveAccountPlanFetch: AccountPlanFetch = { request in
    let (data, response) = try await URLSession.shared.executeRequest(request)
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    return (data, http.statusCode)
}

// MARK: - Route

func registerAccountPlanRoute(
    _ router: some RouterMethods<SewnRequestContext>,
    fetch: @escaping AccountPlanFetch = liveAccountPlanFetch,
    environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
) {
    router.get("/v1/account/plan") { _, context async throws -> AccountPlanResponse in
        guard let token = context.authToken else {
            throw HTTPError(.unauthorized, message: "Missing auth token")
        }
        let env = environment()
        guard
            let supabaseURLString = env["SUPABASE_URL"],
            let anonKey = env["SUPABASE_ANON_KEY"],
            let url = URL(string: "\(supabaseURLString)/rest/v1/rpc/ambient_my_plan")
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }

        // A `returns table` RPC answers a JSON array, 0 or 1 rows here. No
        // `vnd.pgrst.object+json`: that would turn zero rows into a 406.
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 10
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = Data("{}".utf8)

        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(urlRequest)
        } catch {
            // Transport failure — the plan is unknown, the app keeps what it
            // knew and may retry; never hold the request for URLSession's 60 s.
            throw HTTPError(.badGateway, message: "Plan service unreachable — retry")
        }

        let plan = try AccountPlanMapper.response(status: status, data: data)
        // The plan word and Stripe's status only — never a customer or price id.
        let standing = plan.status ?? (plan.known ? "no subscription" : "rpc missing")
        context.logger.info("Account plan: \(plan.plan) (\(standing), upstream \(status))")
        return plan
    }
}
