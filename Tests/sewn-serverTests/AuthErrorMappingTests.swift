//
//  AuthErrorMappingTests.swift
//  sewn-serverTests
//
//  Supabase auth failures as the app sees them. Unmapped, each one reached
//  the client as a bare 500 — a wrong password read like a crash, and a
//  revoked session could not be told from a server that was down.
//

import Supabase
import Foundation
import Hummingbird
import XCTest
@testable import sewn_server

final class AuthErrorMappingTests: XCTestCase {

    private func api(_ code: ErrorCode, status: Int, message: String = "gotrue says") -> AuthError {
        .api(
            message: message,
            errorCode: code,
            underlyingData: Data(),
            underlyingResponse: HTTPURLResponse(
                url: URL(string: "https://example.invalid")!,
                statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func mapped(_ error: Error) -> Hummingbird.HTTPError? {
        authHTTPError(error) as? Hummingbird.HTTPError
    }

    func testAWrongPasswordIsA401WithASentence() {
        let error = mapped(api(.invalidCredentials, status: 400))
        XCTAssertEqual(error?.status, .unauthorized)
        XCTAssertEqual(error?.body, "Wrong email or password.")
    }

    func testAnUnconfirmedEmailIsA403TheAppRoutesToTheCode() {
        XCTAssertEqual(mapped(api(.emailNotConfirmed, status: 400))?.status, .forbidden)
    }

    func testAnExpiredCodeIsA401() {
        XCTAssertEqual(mapped(api(.otpExpired, status: 403))?.status, .unauthorized)
    }

    func testARevokedRefreshTokenIsA401SoTheAppSignsOut() {
        XCTAssertEqual(mapped(api(.refreshTokenNotFound, status: 400))?.status, .unauthorized)
        XCTAssertEqual(mapped(api(.refreshTokenAlreadyUsed, status: 400))?.status, .unauthorized)
    }

    func testAWeakPasswordKeepsSupabasesReason() {
        let error = mapped(AuthError.weakPassword(message: "Too short.", reasons: ["length"]))
        XCTAssertEqual(error?.status, .unprocessableContent)
        XCTAssertEqual(error?.body, "Too short.")
    }

    func testAnUnmappedClientErrorKeepsItsStatusAndSentence() {
        let error = mapped(api(.unknown, status: 422, message: "Something specific."))
        XCTAssertEqual(error?.status, .unprocessableContent)
        XCTAssertEqual(error?.body, "Something specific.")
    }

    func testAnUpstreamServerErrorIsABadGateway() {
        XCTAssertEqual(mapped(api(.unexpectedFailure, status: 500))?.status, .badGateway)
    }

    func testANonAuthErrorPassesThrough() {
        let original = Hummingbird.HTTPError(.badRequest, message: "as thrown")
        XCTAssertEqual(mapped(original)?.body, "as thrown")
    }
}
