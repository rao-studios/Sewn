//
//  AccountPlanTests.swift
//  sewn-serverTests
//
//  GET /v1/account/plan — PostgREST's answer to `ambient_my_plan` as the app
//  sees it. The mapper is pure; the route runs with a recording fetch and an
//  injected environment, so nothing here reaches Supabase.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import sewn_server

final class AccountPlanTests: XCTestCase {

    // MARK: - Fixtures

    /// A trialing row, with the two columns Sewn must not forward.
    private static let plusRow = Data("""
    [{"is_plus":true,"status":"trialing","price_id":"price_month","interval":"month",
      "current_period_start":"2026-09-26T10:00:00+00:00","current_period_end":"2026-10-03T10:00:00+00:00",
      "cancel_at_period_end":false,"trial_end":"2026-10-03T10:00:00+00:00",
      "stripe_customer_id":"cus_secret","livemode":true}]
    """.utf8)

    /// A subscription that ended: a row, but not Plus.
    private static let canceledRow = Data("""
    [{"is_plus":false,"status":"canceled","price_id":"price_year","interval":"year",
      "current_period_start":"2025-09-01T00:00:00+00:00","current_period_end":"2026-09-01T00:00:00+00:00",
      "cancel_at_period_end":true,"trial_end":null,
      "stripe_customer_id":"cus_secret","livemode":true}]
    """.utf8)

    private static let noRows = Data("[]".utf8)

    private func httpError(_ body: () throws -> AccountPlanResponse) -> HTTPError? {
        do { _ = try body(); return nil } catch { return error as? HTTPError }
    }

    // MARK: - Mapper

    func testAPlusRowIsKnownAndPlus() throws {
        let plan = try AccountPlanMapper.response(status: 200, data: Self.plusRow)
        XCTAssertTrue(plan.known)
        XCTAssertEqual(plan.plan, "plus")
        XCTAssertTrue(plan.isPlus)
        XCTAssertEqual(plan.status, "trialing")
        XCTAssertEqual(plan.priceId, "price_month")
        XCTAssertEqual(plan.interval, "month")
        XCTAssertEqual(plan.currentPeriodStart, "2026-09-26T10:00:00+00:00")
        XCTAssertEqual(plan.currentPeriodEnd, "2026-10-03T10:00:00+00:00")
        XCTAssertFalse(plan.cancelAtPeriodEnd)
        XCTAssertEqual(plan.trialEnd, "2026-10-03T10:00:00+00:00")
    }

    func testACanceledRowIsKnownAndFree() throws {
        let plan = try AccountPlanMapper.response(status: 200, data: Self.canceledRow)
        XCTAssertTrue(plan.known)
        XCTAssertEqual(plan.plan, "free")
        XCTAssertFalse(plan.isPlus)
        XCTAssertEqual(plan.status, "canceled", "the app reads the word; the bit decides")
        XCTAssertTrue(plan.cancelAtPeriodEnd)
        XCTAssertNil(plan.trialEnd)
    }

    func testNoRowsIsKnownAndFree() throws {
        let plan = try AccountPlanMapper.response(status: 200, data: Self.noRows)
        XCTAssertTrue(plan.known)
        XCTAssertEqual(plan.plan, "free")
        XCTAssertFalse(plan.isPlus)
        XCTAssertNil(plan.status)
    }

    func testAMissingRPCIsUnknownWithoutThrowing() throws {
        let plan = try AccountPlanMapper.response(status: 404, data: Data(#"{"code":"PGRST202"}"#.utf8))
        XCTAssertFalse(plan.known)
        XCTAssertEqual(plan.plan, "free")
        XCTAssertFalse(plan.isPlus)
    }

    func testARejectedJWTIsA401SoTheAppRefreshes() {
        for status in [401, 403] {
            let error = httpError { try AccountPlanMapper.response(status: status, data: Data()) }
            XCTAssertEqual(error?.status, .unauthorized, "upstream \(status)")
        }
    }

    func testAnUpstreamFailureIsABadGateway() {
        let error = httpError { try AccountPlanMapper.response(status: 500, data: Data()) }
        XCTAssertEqual(error?.status, .badGateway)
        XCTAssertTrue(error?.body?.contains("500") == true, String(describing: error?.body))
    }

    func testAMalformed200Throws() {
        for body in ["not json", #"{"is_plus":true}"#, #"[{"status":"active"}]"#] {
            let error = httpError { try AccountPlanMapper.response(status: 200, data: Data(body.utf8)) }
            XCTAssertEqual(error?.status, .badGateway, body)
        }
    }

    func testTheWireIsSnakeCaseAndCarriesNoStripeIds() throws {
        let plan = try AccountPlanMapper.response(status: 200, data: Self.plusRow)
        let encoded = try JSONEncoder().encode(plan)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "known", "plan", "is_plus", "status", "price_id", "interval",
            "current_period_start", "current_period_end", "cancel_at_period_end", "trial_end",
        ])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("cus_secret"))
        // And the same keys read back: Ambient decodes exactly this shape.
        XCTAssertEqual(try JSONDecoder().decode(AccountPlanResponse.self, from: encoded).plan, "plus")
    }

    // MARK: - Route

    private static let alice = "0B9E2C1A-5D3F-4E6B-9A7C-1234567890AB"
    private static let acceptAsAlice: AuthMiddleware.Validate = { _ in
        TokenValidator.ValidatedUser(userId: alice, displayName: "Alice", expiresAt: .distantFuture)
    }
    private static let supabaseEnvironment: @Sendable () -> [String: String] = {
        ["SUPABASE_URL": "https://supabase.test", "SUPABASE_ANON_KEY": "anon"]
    }

    /// The real AuthMiddleware and the real route; only the network is faked.
    private func app(
        fetch: @escaping AccountPlanFetch,
        environment: @escaping @Sendable () -> [String: String] = supabaseEnvironment
    ) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        let protected = router.add(middleware: AuthMiddleware(validate: Self.acceptAsAlice))
        registerAccountPlanRoute(protected, fetch: fetch, environment: environment)
        return Application(router: router)
    }

    private static func decode(_ response: TestResponse) throws -> AccountPlanResponse {
        try JSONDecoder().decode(AccountPlanResponse.self, from: Data(String(buffer: response.body).utf8))
    }

    func testTheRouteAsksPostgRESTWithTheCallersJWT() async throws {
        let recorded = LockedValue<[URLRequest]>([])
        let fetch: AccountPlanFetch = { request in
            recorded.withLock { $0.append(request) }
            return (Self.noRows, 200)
        }
        try await app(fetch: fetch).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get, headers: [.authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .ok)
                let plan = try Self.decode(response)
                XCTAssertTrue(plan.known)
                XCTAssertEqual(plan.plan, "free")
            }
        }
        XCTAssertEqual(recorded.withLock { $0.count }, 1)
        let sent = try XCTUnwrap(recorded.withLock { $0.first })
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.host, "supabase.test")
        XCTAssertEqual(sent.url?.path, "/rest/v1/rpc/ambient_my_plan")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer good")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "anon")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json",
                       "never vnd.pgrst.object+json: zero rows would be a 406")
        XCTAssertEqual(sent.timeoutInterval, 10)
        XCTAssertEqual(sent.httpBody, Data("{}".utf8))
    }

    func testAPlusAnswerReachesTheAppAsPlus() async throws {
        try await app(fetch: { _ in (Self.plusRow, 200) }).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get, headers: [.authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .ok)
                let plan = try Self.decode(response)
                XCTAssertEqual(plan.plan, "plus")
                XCTAssertEqual(plan.status, "trialing")
                XCTAssertFalse(String(buffer: response.body).contains("cus_secret"))
            }
        }
    }

    func testAnUnreachablePlanServiceIsA502() async throws {
        try await app(fetch: { _ in throw URLError(.cannotConnectToHost) }).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get, headers: [.authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .badGateway)
                XCTAssertTrue(String(buffer: response.body).contains("retry"), String(buffer: response.body))
            }
        }
    }

    func testAMissingRPCIsA200TheAppReadsAsUnknown() async throws {
        try await app(fetch: { _ in (Data(), 404) }).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get, headers: [.authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertFalse(try Self.decode(response).known)
            }
        }
    }

    func testARejectedJWTUpstreamIsA401() async throws {
        try await app(fetch: { _ in (Data(), 401) }).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get, headers: [.authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testAMissingEnvironmentIsA500BeforeAnythingIsDialled() async throws {
        let calls = LockedValue(0)
        let fetch: AccountPlanFetch = { _ in calls.withLock { $0 += 1 }; return (Self.noRows, 200) }
        try await app(fetch: fetch, environment: { [:] }).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get, headers: [.authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .internalServerError)
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testNoBearerNeverReachesSupabase() async throws {
        let calls = LockedValue(0)
        let fetch: AccountPlanFetch = { _ in calls.withLock { $0 += 1 }; return (Self.noRows, 200) }
        // Through the middleware: refused at the gate.
        try await app(fetch: fetch).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        // And the route's own guard, should it ever be registered elsewhere.
        let bare = Router(context: SewnRequestContext.self)
        registerAccountPlanRoute(bare, fetch: fetch, environment: Self.supabaseEnvironment)
        try await Application(router: bare).test(.router) { client in
            try await client.execute(uri: "/v1/account/plan", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(String(buffer: response.body).contains("Missing auth token"))
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }
}
