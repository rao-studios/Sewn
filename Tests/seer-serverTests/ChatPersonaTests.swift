//
//  ChatPersonaTests.swift
//  seer-serverTests
//
//  The personality section of handleChat's system prompt: without a
//  persona object she is Seer; with one she is whoever the client named.
//

import XCTest
@testable import seer_server

final class ChatPersonaTests: XCTestCase {

    func testAbsentPersonaIsSeer() {
        let resolved = resolveChatPersona(inline: nil, stored: nil)
        XCTAssertEqual(resolved.name, "Seer")
        XCTAssertTrue(resolved.voice.contains("close confidante"))
        let section = chatPersonaSection(resolved, memoryInstruction: "Remember them.")
        XCTAssertTrue(section.hasPrefix("Your name is Seer."))
        XCTAssertTrue(section.contains("close confidante"))
        XCTAssertTrue(section.contains("Remember them."))
    }

    func testInlinePersonaNamesTheClient() {
        let resolved = resolveChatPersona(
            inline: ChatPersona(
                name: "Mary",
                voice: "You are Mary — a companion who ACTS."),
            stored: nil)
        XCTAssertEqual(resolved.name, "Mary")
        XCTAssertEqual(resolved.voice, "You are Mary — a companion who ACTS.")
        let section = chatPersonaSection(resolved, memoryInstruction: "")
        XCTAssertTrue(section.hasPrefix("Your name is Mary."))
        XCTAssertFalse(section.contains("Your name is Seer."))
    }

    func testInlineNameWinsOverStoredPersonality() {
        let stored = Personality.defaults.first { $0.id == "scholar" }
        let resolved = resolveChatPersona(
            inline: ChatPersona(name: "Mary", voice: nil),
            stored: stored)
        XCTAssertEqual(resolved.name, "Mary")
        XCTAssertEqual(resolved.voice, stored?.systemFragment)
        XCTAssertEqual(resolved.citationEmphasis, true)
    }

    func testBlankInlineFieldsFallThroughToSeer() {
        let resolved = resolveChatPersona(
            inline: ChatPersona(name: "  ", voice: ""),
            stored: nil)
        XCTAssertEqual(resolved, .default)
    }

    func testRequestDecodesPersonaObject() throws {
        let json = """
        {
          "messages": [{"role": "user", "content": "hi"}],
          "seer": {"owner_id": "o1"},
          "persona": {"name": "Mary", "voice": "You are Mary."}
        }
        """
        let request = try JSONDecoder().decode(
            ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.persona?.name, "Mary")
        XCTAssertEqual(request.persona?.voice, "You are Mary.")
    }

    func testOpeningPromptUsesInlinePersona() {
        let prompt = realtimeOpeningSystemPrompt(
            persona: ChatPersona(name: "Mary", voice: "You are Mary — you ACT."))
        XCTAssertTrue(prompt.hasPrefix("Your name is Mary."))
        XCTAssertTrue(prompt.contains("You are Mary — you ACT."))
        XCTAssertFalse(prompt.contains("Your name is Seer."))
        XCTAssertTrue(prompt.contains("You act through your tools"))
    }
}
