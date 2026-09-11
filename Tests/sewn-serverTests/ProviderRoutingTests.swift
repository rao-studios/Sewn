//
//  ProviderRoutingTests.swift
//  sewn-serverTests
//
//  The `provider` field on the wire, the /v1/providers row, and the pure
//  message mapping the on-device backend uses. No network, no GPU.
//

import XCTest
@testable import sewn_server

final class RequestProviderDecodingTests: XCTestCase {

    func testAnAbsentProviderDecodesToNilOnEveryRoute() throws {
        let skills = try JSONDecoder().decode(
            SkillsCompleteRequest.self,
            from: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8))
        XCTAssertNil(skills.provider)

        let complete = try JSONDecoder().decode(
            CompleteRequest.self,
            from: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8))
        XCTAssertNil(complete.provider)
    }

    func testTheProviderRidesTheSkillsAndCompleteBodies() throws {
        let skills = try JSONDecoder().decode(
            SkillsCompleteRequest.self,
            from: Data(#"{"messages":[{"role":"user","content":"hi"}],"provider":"local"}"#.utf8))
        XCTAssertEqual(skills.provider, .local)

        let complete = try JSONDecoder().decode(
            CompleteRequest.self,
            from: Data(#"{"messages":[{"role":"user","content":"hi"}],"provider":"tinker"}"#.utf8))
        XCTAssertEqual(complete.provider, .tinker)
    }

    /// An unknown provider is a 400, not a silent fallback: a client that
    /// misspells its backend should hear about it.
    func testAnUnknownProviderFailsTheDecode() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SkillsCompleteRequest.self,
                from: Data(#"{"messages":[],"provider":"hosted"}"#.utf8)))
    }
}

final class ProviderInfoTests: XCTestCase {

    func testAnUnbuiltLocalBackendSaysSoRatherThanClaimingReadiness() {
        let info = providerInfo(.local, localState: .cold, localBuilt: false)
        XCTAssertFalse(info.available)
        XCTAssertEqual(info.id, "local")
        XCTAssertNotNil(info.reason)
    }

    func testHostedRowsCarryTheirModelAndNeverClaimVisionOrSpeech() {
        let info = providerInfo(.mistral, localState: .cold, localBuilt: true)
        XCTAssertEqual(info.model, ModelConfig.chatModel(for: .mistral))
        XCTAssertTrue(info.capabilities.chat)
        XCTAssertFalse(info.capabilities.vision)
        XCTAssertFalse(info.capabilities.speech)
    }

    func testLoadingProgressIsReportedOnlyForTheLocalRow() {
        let local = providerInfo(.local, localState: .loading(0.4), localBuilt: true)
        XCTAssertEqual(local.progress, 0.4)
        let hosted = providerInfo(.tinker, localState: .loading(0.4), localBuilt: true)
        XCTAssertNil(hosted.progress)
    }
}

final class LocalMessageMapperTests: XCTestCase {

    func testConsecutiveSameRoleTurnsMergeIntoStrictAlternation() {
        let turns = LocalMessageMapper.alternating([
            .init(role: "user", content: "open Calendar"),
            .init(role: "user", content: "[skill result — look]: empty"),
            .init(role: "assistant", content: "done"),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns[0].isUser)
        XCTAssertTrue(turns[0].text.contains("open Calendar"))
        XCTAssertTrue(turns[0].text.contains("skill result"))
        XCTAssertFalse(turns[1].isUser)
    }

    func testEmptyTurnsDropRatherThanBreakingTheTemplate() {
        let turns = LocalMessageMapper.alternating([
            .init(role: "user", content: "hi"),
            .init(role: "assistant", content: "   "),
            .init(role: "user", content: "still there?"),
        ])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "hi\n\nstill there?")
    }

    func testTheToolRosterIsSpelledOutForASmallModel() {
        let text = LocalMessageMapper.systemText(
            "You are Mary.",
            tools: [.init(
                type: "function",
                function: .init(
                    name: "bring_window_forward",
                    description: "Raise a window",
                    parameters: nil))])
        XCTAssertTrue(text.contains("You are Mary."))
        XCTAssertTrue(text.contains("bring_window_forward"))
        XCTAssertTrue(text.contains("<tool_call>"))
    }

    func testAToolRendersAsTheOpenAIFunctionShape() throws {
        let spec = LocalMessageMapper.toolSpec(from: .init(
            type: "function",
            function: .init(
                name: "look",
                description: "Look ahead",
                parameters: .object(["type": .string("object")]))))
        XCTAssertEqual(spec["type"] as? String, "function")
        let function = try XCTUnwrap(spec["function"] as? [String: any Sendable])
        XCTAssertEqual(function["name"] as? String, "look")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: any Sendable])
        XCTAssertEqual(parameters["type"] as? String, "object")
    }
}
