//
//  CodeCompleteTests.swift
//  sewn-serverTests
//

import XCTest
@testable import sewn_server

final class CodeCompleteWireTests: XCTestCase {

    func testTokenBudgetMatchesACodingRound() {
        XCTAssertEqual(codeCompleteMaxTokens(nil), 2048)
        XCTAssertEqual(codeCompleteMaxTokens(8192), 4096)
        XCTAssertEqual(codeCompleteMaxTokens(8), 32)
        XCTAssertNotEqual(codeCompleteMaxTokens(nil), skillsCompleteMaxTokens(nil))
    }

    func testDefaultCodingModelIsCodestralNotTheChatModel() {
        XCTAssertEqual(ModelConfig.defaultCodingModel, "codestral-latest")
        XCTAssertTrue(ModelConfig.isMistralModel(ModelConfig.defaultCodingModel))
    }

    func testRequestReusesTheSkillsCompleteWire() throws {
        let json = """
        {
          "instructions": "Edit the project.",
          "messages": [{"role": "user", "content": "add a guard"}],
          "tools": [{
            "type": "function",
            "function": {"name": "apply_patch", "description": "patch a file"}
          }],
          "max_tokens": 2048
        }
        """
        let request = try JSONDecoder().decode(
            CodeCompleteRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.tools?.first?.function?.name, "apply_patch")
        XCTAssertEqual(skillsCompleteChatTools(request.tools)?.count, 1)
    }
}
