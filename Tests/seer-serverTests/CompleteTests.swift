//
//  CompleteTests.swift
//  seer-serverTests
//
//  The complete route's prompt construction and wire shapes — no network
//  anywhere. The load-bearing pins: instructions ride unadorned (no persona),
//  the response has a `text` field and no `contribution`, and a JSON-only
//  contract in `instructions` is still the system prompt the model sees.
//

import XCTest
@testable import seer_server

// MARK: - Prompts

final class CompletePromptTests: XCTestCase {

    func testInstructionsRideUnadornedAsTheSystemPrompt() {
        let contract = """
        Reply with ONLY a JSON object: {"precis": string, "labels": [string]}.
        """
        XCTAssertEqual(completeSystemPrompt(instructions: contract), contract)
        XCTAssertNil(completeSystemPrompt(instructions: nil))
        XCTAssertNil(completeSystemPrompt(instructions: ""))
    }

    func testUserTextJoinsMessageContentsInOrder() {
        let text = completeUserText(messages: [
            CompleteMessage(role: "user", content: "struct Ledger {}"),
            CompleteMessage(role: "user", content: "public func ingest()"),
        ])
        XCTAssertEqual(text, "struct Ledger {}\npublic func ingest()")
    }

    func testUserTextDropsEmptyContents() {
        XCTAssertEqual(
            completeUserText(messages: [
                CompleteMessage(role: "user", content: ""),
                CompleteMessage(role: "user", content: "only this"),
            ]),
            "only this")
    }
}

// MARK: - Wire shapes

final class CompleteWireTests: XCTestCase {

    func testRequestDecodesWithoutASeerScope() throws {
        let json = """
        {
          "instructions": "Reply with ONLY JSON.",
          "messages": [{"role": "user", "content": "struct Foo {}"}],
          "max_tokens": 256
        }
        """
        let request = try JSONDecoder().decode(CompleteRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.instructions, "Reply with ONLY JSON.")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages[0].role, "user")
        XCTAssertEqual(request.messages[0].content, "struct Foo {}")
        XCTAssertNil(request.tools)
        XCTAssertEqual(request.maxTokens, 256)
        XCTAssertNil(request.temperature)
    }

    func testRequestAcceptsAnUnusedToolsArray() throws {
        let json = """
        {
          "messages": [{"role": "user", "content": "hi"}],
          "tools": [{"type": "function", "function": {"name": "lookup"}}]
        }
        """
        let request = try JSONDecoder().decode(CompleteRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.tools?.count, 1)
        XCTAssertEqual(request.tools?.first?.function?.name, "lookup")
    }

    func testResponseEncodesTextAndOmitsContribution() throws {
        let data = try JSONEncoder().encode(CompleteResponse(text: "{\"precis\":\"a\",\"labels\":[\"b\"]}"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(
            object["text"] as? String,
            "{\"precis\":\"a\",\"labels\":[\"b\"]}")
        XCTAssertNil(object["contribution"])
        XCTAssertNil(object["tool_calls"])
    }

    func testAJSONContractInInstructionsIsStillTheSystemPrompt() {
        // The annotator regression: stuffing the JSON shape into instructions
        // only works if those instructions are the system prompt, not a
        // persona preface the chat pipeline would wrap.
        let contract = "Reply with ONLY a JSON object with keys precis and labels."
        let system = completeSystemPrompt(instructions: contract)
        XCTAssertEqual(system, contract)
        XCTAssertTrue(system?.contains("precis") == true)
        XCTAssertTrue(system?.contains("labels") == true)
        XCTAssertFalse(system?.lowercased().contains("persona") == true)
        XCTAssertFalse(system?.lowercased().contains("gita") == true)
    }

    func testAThinkingUtilityModelIsReplacedWithTheFastDefault() {
        XCTAssertEqual(
            completeGenerationModel("thinkingmachines/Inkling"),
            ModelConfig.defaultUtilityModel)
        XCTAssertEqual(completeGenerationModel("mistral-tiny"), "mistral-tiny")
    }

    func testCompleteCapsTheTokenBudget() {
        XCTAssertEqual(completeMaxTokens(nil), 256)
        XCTAssertEqual(completeMaxTokens(8), 32)
        // A stated budget is honoured: the drafter's recipe needs the room.
        XCTAssertEqual(completeMaxTokens(1024), 1024)
        XCTAssertEqual(completeMaxTokens(4096), 2048)
    }
}
