//
//  LocalOnlyGrantTests.swift
//  sewn-serverTests
//
//  A local app with no account may take the on-device lane: the stack secret
//  names it, and on six routes that is identity enough. Everywhere else a
//  bearer is still required, an open server grants nothing, a presented
//  token is never downgraded, and a local-only caller asking for a hosted
//  provider is refused before anything is dialled.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import RaoStack
import XCTest
@testable import sewn_server

final class LocalOnlyGrantTests: XCTestCase {

    private let shared = StackMode.multiApp(StackKeyring(fixed: [.ambient: "s3cret", .craft: "other"]))

    private static let rejectEveryToken: AuthMiddleware.Validate = { _ in
        throw HTTPError(.unauthorized, message: "Invalid or expired access token")
    }
    private static let alice = "0B9E2C1A-5D3F-4E6B-9A7C-1234567890AB"
    private static let acceptAsAlice: AuthMiddleware.Validate = { _ in
        TokenValidator.ValidatedUser(userId: alice, displayName: "Alice", expiresAt: .distantFuture)
    }

    /// Who the caller became: owner | lane | token.
    private static func whoami(_ context: SewnRequestContext) -> String {
        "\(context.authUserId ?? "none")|\(context.isLocalOnly ? "local-only" : "account")|\(context.authToken ?? "-")"
    }

    /// The real stack middleware and the real AuthMiddleware; routes at the
    /// real paths that say who the caller became.
    private func app(
        _ stack: StackMode,
        validate: @escaping AuthMiddleware.Validate = rejectEveryToken
    ) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        if stack.isLocal {
            router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: stack))
        }
        let protected = router.add(middleware: AuthMiddleware(validate: validate))
        protected.post("/v1/chat/completions") { _, c in Self.whoami(c) }
        protected.post("/v1/complete") { _, c in Self.whoami(c) }
        protected.get("/v1/providers") { _, c in Self.whoami(c) }
        protected.post("/v1/providers/local/warm") { _, c in Self.whoami(c) }
        protected.get("/v1/providers/local/sinatra/traces/:traceId") { _, c in Self.whoami(c) }
        protected.get("/v1/providers/local/sinatra/analysis") { _, c in Self.whoami(c) }
        // Not granted: the same path under another method, and three account routes.
        protected.delete("/v1/providers/local/sinatra/traces/:traceId") { _, c in Self.whoami(c) }
        protected.post("/v1/search") { _, c in Self.whoami(c) }
        protected.get("/v1/account/keys") { _, c in Self.whoami(c) }
        protected.get("/v1/account/plan") { _, c in Self.whoami(c) }
        return Application(router: router)
    }

    private static let granted: [(HTTPRequest.Method, String)] = [
        (.post, "/v1/chat/completions"),
        (.post, "/v1/complete"),
        (.get, "/v1/providers"),
        (.post, "/v1/providers/local/warm"),
        (.get, "/v1/providers/local/sinatra/traces/\(UUID().uuidString)"),
        (.get, "/v1/providers/local/sinatra/analysis"),
    ]

    // MARK: - The grant

    func testAGrantedRouteAdmitsTheStacksAppWithoutABearer() async throws {
        try await app(shared).test(.router) { client in
            for (method, uri) in Self.granted {
                try await client.execute(uri: uri, method: method, headers: [.ambientSecret: "s3cret"]) { response in
                    XCTAssertEqual(response.status, .ok, "\(method) \(uri)")
                    XCTAssertEqual(String(buffer: response.body), "local-ambient|local-only|-", "\(method) \(uri)")
                }
            }
            try await client.execute(uri: "/v1/providers", method: .get, headers: [.ambientSecret: "other"]) { response in
                XCTAssertEqual(String(buffer: response.body), "local-craft|local-only|-",
                               "the owner is the app whose secret matched")
            }
        }
    }

    func testEveryOtherProtectedRouteStillWantsABearer() async throws {
        try await app(shared).test(.router) { client in
            let refused: [(HTTPRequest.Method, String)] = [
                (.post, "/v1/search"),
                (.get, "/v1/account/keys"),
                (.get, "/v1/account/plan"),
                (.delete, "/v1/providers/local/sinatra/traces/\(UUID().uuidString)"),
            ]
            for (method, uri) in refused {
                try await client.execute(uri: uri, method: method, headers: [.ambientSecret: "s3cret"]) { response in
                    XCTAssertEqual(response.status, .unauthorized, "\(method) \(uri)")
                }
            }
        }
    }

    func testAnOpenServerGrantsNothing() async throws {
        try await app(.open).test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        // A one-app stack whose launcher named no app: the secret passes, but
        // nothing says who is calling, so there is no owner to grant.
        try await app(.single(secret: "s", app: nil)).test(.router) { client in
            try await client.execute(uri: "/v1/providers", method: .get, headers: [.ambientSecret: "s"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testAPresentedBearerIsNeverDowngraded() async throws {
        try await app(shared).test(.router) { client in
            for header in ["Bearer bad", "Bearer ", "Basic x"] {
                try await client.execute(
                    uri: "/v1/providers", method: .get,
                    headers: [.ambientSecret: "s3cret", .authorization: header]) { response in
                    XCTAssertEqual(response.status, .unauthorized, "\"\(header)\" must not fall back to the grant")
                }
            }
        }
        try await app(shared, validate: Self.acceptAsAlice).test(.router) { client in
            try await client.execute(
                uri: "/v1/providers", method: .get,
                headers: [.ambientSecret: "s3cret", .authorization: "Bearer good"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "\(Self.alice)|account|good")
            }
        }
    }

    // MARK: - The hosted refusal

    func testALocalOnlyCallerRunsOnDeviceOrNotAtAll() throws {
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: .local, isLocalOnly: true, app: .ambient), .local)
        for hosted in [LLMProvider.mistral, .tinker] {
            XCTAssertThrowsError(try LocalOnlyGrant.provider(requested: hosted, isLocalOnly: true, app: .ambient)) { error in
                let http = error as? HTTPError
                XCTAssertEqual(http?.status, .unauthorized)
                XCTAssertTrue(http?.body?.contains("Sign in to Ambient") == true, String(describing: http?.body))
            }
        }
        for any in LLMProvider.allCases {
            XCTAssertEqual(try LocalOnlyGrant.provider(requested: any, isLocalOnly: false, app: nil), any,
                           "an account is never refused a provider here")
        }
    }

    func testNamingNoProviderFollowsTheServerDefault() throws {
        let key = "SEWN_GLOBAL_LLM"
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        setenv(key, "local", 1)
        XCTAssertEqual(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient), .local)
        unsetenv(key)
        XCTAssertThrowsError(try LocalOnlyGrant.provider(requested: nil, isLocalOnly: true, app: .ambient),
                             "a hosted default is never reached by omission")
    }

    /// The real routes, with no bearer and a hosted provider: refused before
    /// retrieval, Sinatra or a model is touched. Never `local` here: on a Mac
    /// with MLX built it would load a model.
    func testTheRealRoutesRefuseAHostedProviderToALocalCaller() async throws {
        let router = Router(context: SewnRequestContext.self)
        router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: shared))
        let protected = router.add(middleware: AuthMiddleware(validate: Self.rejectEveryToken))
        let modelProvider = ModelProvider(logger: Logger(label: "local-only-grant-tests"))
        try registerChatCompletionsRoute(protected, Sewn(stack: shared), modelProvider: modelProvider)
        registerCompleteRoute(protected, modelProvider: modelProvider)
        let headers: HTTPFields = [.ambientSecret: "s3cret", .contentType: "application/json"]

        try await Application(router: router).test(.router) { client in
            for stream in [false, true] {
                let chat = #"{"messages":[{"role":"user","content":"hi"}],"provider":"mistral","stream":\#(stream),"sewn":{"owner_id":"whatever"}}"#
                try await client.execute(
                    uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(string: chat)) { response in
                    XCTAssertEqual(response.status, .unauthorized, "stream: \(stream)")
                    XCTAssertTrue(String(buffer: response.body).contains("Sign in to Ambient"),
                                  String(buffer: response.body))
                }
            }
            let complete = #"{"messages":[{"role":"user","content":"hi"}],"provider":"mistral"}"#
            try await client.execute(
                uri: "/v1/complete", method: .post, headers: headers,
                body: ByteBuffer(string: complete)) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    // MARK: - Pins

    func testTheLocalOwnerIsNamedForTheApp() {
        XCTAssertEqual(LocalOnlyGrant.ownerId(for: .ambient), "local-ambient",
                       "Ambient's SewnSession.localOwnerID mirrors this string")
        XCTAssertNil(UUID(uuidString: LocalOnlyGrant.ownerId(for: .ambient)),
                     "a Supabase id is a UUID; a local owner can never collide with one")
    }
}
