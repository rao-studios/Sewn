//
//  SkillsCompleteTests.swift
//  sewn-serverTests
//
//  `/v1/skills/complete` prompt construction and wire shapes — no network.
//  Complements CompleteTests: this route keeps message roles and emits
//  tool_calls; complete flattens messages and never does.
//

import XCTest
@testable import sewn_server

final class SkillsCompletePromptTests: XCTestCase {

    func testInstructionsRideUnadornedAsTheSystemPrompt() {
        let contract = "Call tools by name. Do not invent names."
        XCTAssertEqual(skillsCompleteSystemPrompt(instructions: contract), contract)
        XCTAssertNil(skillsCompleteSystemPrompt(instructions: nil))
        XCTAssertNil(skillsCompleteSystemPrompt(instructions: ""))
    }

    func testMessagesKeepRolesAndDropEmptyContents() {
        let mapped = skillsCompleteMessages([
            SkillsCompleteMessage(role: "user", content: "open Calendar"),
            SkillsCompleteMessage(role: "assistant", content: ""),
            SkillsCompleteMessage(role: "user", content: "[skill result — look]: ok"),
        ])
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].role, "user")
        XCTAssertEqual(mapped[0].content, "open Calendar")
        XCTAssertEqual(mapped[1].role, "user")
        XCTAssertTrue(mapped[1].content.contains("look"))
    }
}

final class SkillsCompleteWireTests: XCTestCase {

    func testRequestDecodesToolsWithParametersAndNoSewnScope() throws {
        let json = """
        {
          "instructions": "Use the roster.",
          "messages": [
            {"role": "user", "content": "raise TextEdit"},
            {"role": "user", "content": "[skill result — look]: untitled"}
          ],
          "tools": [{
            "type": "function",
            "function": {
              "name": "bring_window_forward",
              "description": "Raise a window",
              "parameters": {
                "type": "object",
                "properties": {
                  "app": {"type": "string", "description": "bundle or name"}
                },
                "required": ["app"]
              }
            }
          }],
          "max_tokens": 800
        }
        """
        let request = try JSONDecoder().decode(
            SkillsCompleteRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.instructions, "Use the roster.")
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.tools?.count, 1)
        XCTAssertEqual(request.tools?.first?.function?.name, "bring_window_forward")
        XCTAssertEqual(request.maxTokens, 800)
        let tools = skillsCompleteChatTools(request.tools)
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?.function.name, "bring_window_forward")
    }

    func testResponseEncodesToolCallsAndOmitsThemWhenEmpty() throws {
        let withCalls = try JSONEncoder().encode(SkillsCompleteResponse(
            text: "",
            toolCalls: [SkillsCompleteToolCall(
                name: "look", arguments: "{\"direction\":\"ahead\"}")]))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withCalls) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "")
        let calls = try XCTUnwrap(object["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0]["name"] as? String, "look")

        let textOnly = try JSONEncoder().encode(SkillsCompleteResponse(text: "hello"))
        let textObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: textOnly) as? [String: Any])
        XCTAssertEqual(textObject["text"] as? String, "hello")
        XCTAssertNil(textObject["tool_calls"])
        XCTAssertNil(textObject["contribution"])
    }

    func testTokenBudgetMatchesASkillRoundNotAnnotation() {
        XCTAssertEqual(skillsCompleteMaxTokens(nil), 800)
        XCTAssertEqual(skillsCompleteMaxTokens(4096), 2048)
        XCTAssertEqual(skillsCompleteMaxTokens(8), 32)
    }

    func testProseToolCallTagsAreParsed() {
        let text = """
        <tool_call>{"name": "look", "arguments": {"direction": "ahead"}}</tool_call>
        """
        let calls = skillsCompleteParseToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "look")
        XCTAssertTrue(calls[0].arguments.contains("ahead"))
        XCTAssertEqual(skillsCompleteTextStrippingTags(text), "")
    }
}
