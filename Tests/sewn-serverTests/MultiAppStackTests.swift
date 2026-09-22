//
//  MultiAppStackTests.swift
//  sewn-serverTests
//
//  A shared ~/.rao Sewn holds one secret per app. The secret a request
//  carries says which app is calling — the middleware records it on the
//  context — and /health proves whichever app's secret X-Rao-App asks for.
//  An open server's /health JSON must stay byte-for-byte what it was.
//

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import RaoStack
import XCTest
@testable import sewn_server

final class MultiAppStackTests: XCTestCase {

    private typealias KAT = StackSecretTests.KAT

    private let shared = StackMode.multiApp(StackKeyring(fixed: [.ambient: "s3cret", .craft: "other"]))

    /// The real middleware and /health, plus a route that says who called.
    private func app(_ stack: StackMode) -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        if stack.isLocal {
            router.middlewares.add(StackSecretMiddleware<SewnRequestContext>(mode: stack))
        }
        registerHealthRoute(router, stack: stack)
        router.get("/v1/whoami") { _, context in
            context.callerApp?.rawValue ?? "none"
        }
        return Application(router: router)
    }

    func testEachAppsSecretNamesThatApp() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "s3cret"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "ambient")
            }
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "other"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "craft")
            }
        }
    }

    func testAnUnknownSecretIsRefused() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(uri: "/v1/whoami", method: .get, headers: [.ambientSecret: "nope"]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/whoami", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/v1/whoami", method: .get,
                headers: [.ambientSecret: "s3cret", .raoApp: "craft"]) { response in
                XCTAssertEqual(String(buffer: response.body), "ambient",
                               "the app is the secret that matched, never a header the client picked")
            }
        }
    }

    func testABadHostIsRefusedEvenWithASecret() {
        XCTAssertEqual(shared.admit(authority: "evil.example:47080", presented: "s3cret"), .notLoopback)
        XCTAssertThrowsError(try shared.admittedApp(authority: "evil.example:47080", presented: "s3cret")) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .misdirectedRequest)
        }
        XCTAssertEqual(try shared.admittedApp(authority: "127.0.0.1:47080", presented: "other"), .craft)
    }

    func testHealthProvesTheRequestedAppsSecret() async throws {
        try await app(shared).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .raoApp: "craft"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForOther)\""), body)
                XCTAssertTrue(body.contains("\"app\":\"craft\""), body)
                XCTAssertTrue(body.contains("\"contract\":1"), body)
                XCTAssertFalse(body.contains("other"), "the secret never crosses on /health: \(body)")
            }
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .raoApp: "ambient"]) { response in
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"proof\":\"\(KAT.proofForS3cret)\""), body)
                XCTAssertTrue(body.contains("\"app\":\"ambient\""), body)
            }
        }
    }

    func testHealthProvesNothingForAnUnknownApp() async throws {
        try await app(shared).test(.router) { client in
            for requested in ["veil", "nope", ""] {
                try await client.execute(
                    uri: "/health", method: .get,
                    headers: [.ambientNonce: KAT.nonce, .raoApp: requested]) { response in
                    XCTAssertEqual(response.status, .ok, "health is never refused")
                    let body = String(buffer: response.body)
                    XCTAssertTrue(body.contains("\"stack\":\"proof\""), body)
                    XCTAssertFalse(body.contains("\"proof\":"), "no proof for \"\(requested)\": \(body)")
                    XCTAssertFalse(body.contains("\"app\":"), "no app for \"\(requested)\": \(body)")
                    XCTAssertTrue(body.contains("\"contract\":1"), body)
                }
            }
            try await client.execute(uri: "/health", method: .get, headers: [.ambientNonce: KAT.nonce]) { response in
                let body = String(buffer: response.body)
                XCTAssertFalse(body.contains("\"proof\":"), "no app asked for: \(body)")
            }
        }
    }

    func testAnOpenServersHealthIsUnchanged() async throws {
        try await app(.open).test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get,
                headers: [.ambientNonce: KAT.nonce, .raoApp: "ambient"]) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("\"status\":\"healthy\""), body)
                XCTAssertTrue(body.contains("\"stack\":\"open\""), body)
                for key in ["proof", "app", "contract"] {
                    XCTAssertFalse(body.contains("\"\(key)\""), "an open server sends no \(key) key, not even null: \(body)")
                }
                let keys = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
                XCTAssertEqual(Set(keys?.keys.map { $0 } ?? []), ["status", "timestamp", "stack"])
            }
        }
    }

    func testTheModeSaysWhatItIsWithoutASecret() {
        XCTAssertTrue(shared.isLocal)
        XCTAssertNil(shared.singleSecret)
        XCTAssertNotNil(shared.grpcResolver)
        XCTAssertEqual(shared.grpcResolver?("other"), "craft")
        XCTAssertNil(shared.grpcResolver?("nope"))
        XCTAssertFalse(shared.summary.contains("s3cret"))
        XCTAssertFalse(shared.summary.contains("other"))
    }
}
