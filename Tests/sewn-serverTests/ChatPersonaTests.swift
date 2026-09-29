//
//  ChatPersonaTests.swift
//  sewn-serverTests
//
//  The personality section of handleChat's system prompt: without a
//  persona object she is Sewn; with one she is whoever the client named.
//

import XCTest
@testable import sewn_server

final class ChatPersonaTests: XCTestCase {

    func testAbsentPersonaIsSewn() {
        let resolved = resolveChatPersona(inline: nil, stored: nil)
        XCTAssertEqual(resolved.name, "Sewn")
        XCTAssertTrue(resolved.voice.contains("close confidante"))
        let section = chatPersonaSection(resolved, memoryInstruction: "Remember them.")
        XCTAssertTrue(section.hasPrefix("Your name is Sewn."))
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
        XCTAssertFalse(section.contains("Your name is Sewn."))
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

    func testBlankInlineFieldsFallThroughToSewn() {
        let resolved = resolveChatPersona(
            inline: ChatPersona(name: "  ", voice: ""),
            stored: nil)
        XCTAssertEqual(resolved, .default)
    }

    func testRequestDecodesPersonaObject() throws {
        let json = """
        {
          "messages": [{"role": "user", "content": "hi"}],
          "sewn": {"owner_id": "o1"},
          "persona": {"name": "Mary", "voice": "You are Mary."}
        }
        """
        let request = try JSONDecoder().decode(
            ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.persona?.name, "Mary")
        XCTAssertEqual(request.persona?.voice, "You are Mary.")
    }

    func testRequestDecodesTheUserName() throws {
        let json = """
        {
          "messages": [{"role": "user", "content": "hi"}],
          "sewn": {"owner_id": "o1"},
          "persona": {"name": "Mary", "voice": "You are Mary.", "user_name": "Ritesh"}
        }
        """
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.persona?.userName, "Ritesh")
    }

    // MARK: - On-device rendering

    private let mary = ResolvedChatPersona(
        name: "Mary", voice: "You are a voice assistant living on the user's Mac.", citationEmphasis: false)

    private func mentions(_ name: String, in text: String) -> Int {
        text.components(separatedBy: name).count - 1
    }

    func testOnDeviceSaysHerNameOnceAndThatTheUserIsSomeoneElse() {
        let section = localChatPersonaSection(mary, userName: nil, memoryInstruction: "Remember nothing.")
        XCTAssertTrue(section.hasPrefix("Your name is Mary, and you say so whenever you're asked who you are or who they're talking to. Mary is your name, not the user's."))
        XCTAssertTrue(section.contains("never address them by a name"))
        XCTAssertTrue(section.contains("You are a voice assistant living on the user's Mac. Remember nothing."))
        XCTAssertFalse(section.contains(":"), "no speaker labels or fences")
    }

    func testOnDeviceNamesTheUserWhenTheClientKnowsIt() {
        let section = localChatPersonaSection(mary, userName: " Ritesh ", memoryInstruction: "")
        XCTAssertTrue(section.contains("You're talking with Ritesh; Mary is your name and Ritesh is theirs."))
        XCTAssertFalse(section.contains("never address them by a name"))
    }

    func testOnDeviceBlankUserNameIsUnknown() {
        let section = localChatPersonaSection(mary, userName: "  ", memoryInstruction: "")
        XCTAssertTrue(section.contains("You don't know the user's name"))
    }

    func testOnDeviceUserWhoSharesHerName() {
        let section = localChatPersonaSection(mary, userName: "mary", memoryInstruction: "")
        XCTAssertTrue(section.contains("shares your name"))
        XCTAssertFalse(section.contains("not theirs"))
    }

    /// A voice that already names her (an older client) is not named again.
    func testOnDeviceDoesNotRepeatANameTheVoiceAlreadySays() {
        let older = ResolvedChatPersona(
            name: "Mary", voice: "You are Mary — that is your name.", citationEmphasis: false)
        let section = localChatPersonaSection(older, userName: nil, memoryInstruction: "")
        XCTAssertFalse(section.hasPrefix("Your name is Mary"))
        XCTAssertTrue(section.hasPrefix("Mary is your name, not the user's."))
    }

    /// "Mac" appears in "the user's Mac" but does not introduce her there.
    func testOnDeviceNameIsSaidUnlessTheVoiceIntroducesHer() {
        let mac = ResolvedChatPersona(
            name: "Mac", voice: "You are a voice assistant living on the user's Mac.", citationEmphasis: false)
        let section = localChatPersonaSection(mac, userName: nil, memoryInstruction: "")
        XCTAssertTrue(section.hasPrefix("Your name is Mac,"))
    }

    /// Hosted keeps today's section and instructions byte for byte.
    func testHostedSectionAndInstructionsAreUnchanged() {
        XCTAssertEqual(chatPersonaSection(mary, memoryInstruction: "M."),
                       "Your name is Mary.\n\nYou are a voice assistant living on the user's Mac. M.")
        XCTAssertEqual(Sewn.chatInstructions(nil), Sewn.chatBaseRules)
        XCTAssertEqual(Sewn.chatInstructions("Be brief."),
                       "--- CONVERSATIONAL INSTRUCTIONS ---\nBe brief.\n\n" + Sewn.chatBaseRules)
        XCTAssertTrue(Sewn.chatBaseRules.hasPrefix("Keep responses under 6-7 sentences."))
    }

    func testOpeningPromptUsesInlinePersona() {
        let prompt = realtimeOpeningSystemPrompt(
            persona: ChatPersona(name: "Mary", voice: "You are Mary — you ACT."))
        XCTAssertTrue(prompt.hasPrefix("Your name is Mary."))
        XCTAssertTrue(prompt.contains("You are Mary — you ACT."))
        XCTAssertFalse(prompt.contains("Your name is Sewn."))
        XCTAssertTrue(prompt.contains("You act through your tools"))
    }
}
