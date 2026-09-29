//
//  RaoVerifiedKeysTests.swift
//  sewn-serverTests
//
//  POST/GET /v1/account/rao-verified/keys — the Mac's Rao Verified key,
//  registered to the caller's account. A key that is not a P-256 point named
//  by its own id never reaches Supabase; the route runs with a recording
//  fetch and an injected environment, so nothing here reaches Supabase.
//

import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import sewn_server

final class RaoVerifiedKeysTests: XCTestCase {

    // MARK: - Fixtures

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let publicKey = P256.Signing.PrivateKey().publicKey.compressedRepresentation

    private static func registration(
        kid: String? = nil, publicKey: String? = nil, protection: String = "se",
        scope: String = "mac", app: String = "ambient"
    ) -> RaoVerifiedKeyRegistration {
        RaoVerifiedKeyRegistration(
            kid: kid ?? RaoVerifiedKeyCheck.keyID(for: Self.publicKey),
            publicKey: publicKey ?? base64URL(Self.publicKey),
            protection: protection, scope: scope, app: app, appVersion: "1.0.0")
    }

    /// The row the register function returns, with the owner Sewn must not forward.
    private static var row: Data {
        let good = registration()
        return Data("""
        [{"user_id":"0b9e2c1a-5d3f-4e6b-9a7c-1234567890ab","kid":"\(good.kid)","public_key":"\(good.publicKey)",
          "protection":"se","scope":"mac","first_app":"ambient","last_app":"ambient","app_version":"1.0.0",
          "created_at":"2026-09-29T18:00:00+00:00","last_seen_at":"2026-09-29T18:00:00+00:00"}]
        """.utf8)
    }

    // MARK: - The key, checked

    func testARealKeyNamedByItsOwnIdPasses() {
        XCTAssertNil(RaoVerifiedKeyCheck.problem(with: Self.registration()))
        XCTAssertNil(RaoVerifiedKeyCheck.problem(with: Self.registration(protection: "kc", scope: "app", app: "craft")))
    }

    func testAKeyNamedByAnotherIdIsRefused() {
        XCTAssertEqual(RaoVerifiedKeyCheck.problem(with: Self.registration(kid: "0123456789abcdef")),
                       "kid is not this key's id")
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(kid: "ABCDEF0123456789")))
    }

    func testSomethingThatIsNotACompressedP256KeyIsRefused() {
        let uncompressed = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(publicKey: Self.base64URL(uncompressed))))
        // 33 bytes with the right prefix, but no point on the curve.
        let offCurve = Data([0x02]) + Data(repeating: 0xFF, count: 32)
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(
            kid: RaoVerifiedKeyCheck.keyID(for: offCurve), publicKey: Self.base64URL(offCurve))))
        // Standard base64's padding and alphabet are not base64url. (A 33-byte
        // key needs no padding, so the key's own base64 is not a sure test.)
        let good = Self.base64URL(Self.publicKey)
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(publicKey: good + "=")))
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(publicKey: "+" + good.dropFirst())))
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(publicKey: "/" + good.dropFirst())))
    }

    func testOnlyKnownWordsPass() {
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(protection: "eph")))
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(scope: "everyone")))
        XCTAssertNotNil(RaoVerifiedKeyCheck.problem(with: Self.registration(app: "mary")))
    }

    // MARK: - Mapper

    func testTheOwnerIsNeverForwarded() throws {
        let key = try RaoVerifiedKeysMapper.registered(status: 200, data: Self.row)
        XCTAssertEqual(key.scope, "mac")
        let encoded = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        XCTAssertFalse(encoded.contains("user_id"))
        XCTAssertFalse(encoded.contains("0b9e2c1a"))
    }

    // MARK: - Routes

    private static let alice = "0B9E2C1A-5D3F-4E6B-9A7C-1234567890AB"
    private static let acceptAsAlice: AuthMiddleware.Validate = { _ in
        TokenValidator.ValidatedUser(userId: alice, displayName: "Alice", expiresAt: .distantFuture)
    }
    private static let supabaseEnvironment: @Sendable () -> [String: String] = {
        ["SUPABASE_URL": "https://supabase.test", "SUPABASE_ANON_KEY": "anon"]
    }

    private func app(
        fetch: @escaping RaoVerifiedKeysFetch,
        environment: @escaping @Sendable () -> [String: String] = supabaseEnvironment
    ) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        let protected = router.add(middleware: AuthMiddleware(validate: Self.acceptAsAlice))
        registerRaoVerifiedKeysRoutes(protected, fetch: fetch, environment: environment)
        return Application(router: router)
    }

    private static func body(_ registration: RaoVerifiedKeyRegistration) throws -> ByteBuffer {
        ByteBuffer(data: try JSONEncoder().encode(registration))
    }

    private func register(
        _ registration: RaoVerifiedKeyRegistration = registration(),
        fetch: @escaping RaoVerifiedKeysFetch,
        environment: @escaping @Sendable () -> [String: String] = supabaseEnvironment,
        bearer: Bool = true,
        expect: @escaping @Sendable (TestResponse) throws -> Void
    ) async throws {
        try await app(fetch: fetch, environment: environment).test(.router) { client in
            var headers: HTTPFields = [.contentType: "application/json"]
            if bearer { headers[.authorization] = "Bearer good" }
            try await client.execute(
                uri: "/v1/account/rao-verified/keys", method: .post, headers: headers,
                body: try Self.body(registration)
            ) { response in try expect(response) }
        }
    }

    func testRegistrationGoesThroughTheRegisterFunctionWithTheCallersJWT() async throws {
        let recorded = LockedValue<[URLRequest]>([])
        try await register(fetch: { request in
            recorded.withLock { $0.append(request) }
            return (Self.row, 200)
        }) { response in
            XCTAssertEqual(response.status, .ok)
            let key = try JSONDecoder().decode(RaoVerifiedKeyResponse.self, from: Data(String(buffer: response.body).utf8))
            XCTAssertEqual(key.kid, Self.registration().kid)
        }
        let sent = try XCTUnwrap(recorded.withLock { $0.first })
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/rest/v1/rpc/rao_verified_register_key")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer good")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "anon")
        XCTAssertEqual(sent.timeoutInterval, 10)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: String])
        XCTAssertEqual(body["p_kid"], Self.registration().kid)
        XCTAssertEqual(body["p_scope"], "mac")
        XCTAssertEqual(body["p_app"], "ambient")
        XCTAssertNil(body["p_user_id"], "the account is the caller's, never sent")
    }

    func testABadKeyNeverReachesSupabase() async throws {
        let calls = LockedValue(0)
        try await register(Self.registration(kid: "0123456789abcdef"), fetch: { _ in
            calls.withLock { $0 += 1 }
            return (Self.row, 200)
        }) { response in
            XCTAssertEqual(response.status, .badRequest)
            XCTAssertTrue(String(buffer: response.body).contains("kid is not this key's id"))
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testAnUndeployedFunctionIsA404TheAppReadsAsNotYet() async throws {
        try await register(fetch: { _ in (Data(), 404) }) { response in
            XCTAssertEqual(response.status, .notFound)
        }
    }

    func testARejectedJWTUpstreamIsA401() async throws {
        try await register(fetch: { _ in (Data(), 401) }) { response in
            XCTAssertEqual(response.status, .unauthorized)
        }
    }

    func testAnUnreachableSupabaseIsA502() async throws {
        try await register(fetch: { _ in throw URLError(.cannotConnectToHost) }) { response in
            XCTAssertEqual(response.status, .badGateway)
        }
    }

    func testAMissingEnvironmentIsA500BeforeAnythingIsDialled() async throws {
        let calls = LockedValue(0)
        try await register(fetch: { _ in calls.withLock { $0 += 1 }; return (Self.row, 200) },
                           environment: { [:] }) { response in
            XCTAssertEqual(response.status, .internalServerError)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testNoBearerNeverReachesSupabase() async throws {
        let calls = LockedValue(0)
        try await register(fetch: { _ in calls.withLock { $0 += 1 }; return (Self.row, 200) },
                           bearer: false) { response in
            XCTAssertEqual(response.status, .unauthorized)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testTheAccountsKeysAreListedFromItsOwnRows() async throws {
        let recorded = LockedValue<[URLRequest]>([])
        try await app(fetch: { request in
            recorded.withLock { $0.append(request) }
            return (Self.row, 200)
        }).test(.router) { client in
            try await client.execute(
                uri: "/v1/account/rao-verified/keys", method: .get, headers: [.authorization: "Bearer good"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let listed = try JSONDecoder().decode(RaoVerifiedKeysResponse.self, from: Data(String(buffer: response.body).utf8))
                XCTAssertEqual(listed.keys.map(\.kid), [Self.registration().kid])
                XCTAssertFalse(String(buffer: response.body).contains("user_id"))
            }
        }
        let sent = try XCTUnwrap(recorded.withLock { $0.first })
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/rest/v1/rao_verified_keys")
        XCTAssertFalse(sent.url?.query?.contains("user_id") ?? true, "row-level security picks the rows")
    }
}
