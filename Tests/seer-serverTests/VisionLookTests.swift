//
//  VisionLookTests.swift
//  seer-serverTests
//
//  The vision look's prompt construction and wire shapes — no network
//  anywhere. Prompts are pinned by substring the way the realtime opening
//  prompt is; the content-parts encoding is pinned because Pixtral's
//  {"type":"image_url","image_url":{"url":…}} shape is the whole reason
//  Requests.VisionChat exists apart from the plain chat wire.
//

import XCTest
@testable import seer_server

// MARK: - Prompts

final class VisionLookPromptTests: XCTestCase {

    func testDescribePromptIsScreenScopedNotBrowserScoped() {
        let prompt = visionLookSystemPrompt(mode: "describe", authoringContract: nil)
        // The look works anywhere on the computer — the wording must not
        // narrow it back to the browser it started as.
        XCTAssertTrue(prompt.contains("on their screen"))
        XCTAssertFalse(prompt.lowercased().contains("browser"))
        // Conversational commentary with the designer voice available, bounded.
        XCTAssertTrue(prompt.contains("one designer to another"))
        XCTAssertTrue(prompt.contains("1200 characters"))
        XCTAssertTrue(prompt.contains("No preamble"))
    }

    func testDesignPlanPromptCarriesTheContractVerbatim() {
        let contract = "COMMANDS: createFrame {\"x\":number}"
        let prompt = visionLookSystemPrompt(mode: "design_plan", authoringContract: contract)
        XCTAssertTrue(prompt.contains("ONLY a JSON array"))
        XCTAssertTrue(prompt.contains("no code fences"))
        XCTAssertTrue(prompt.contains(contract))
    }

    func testUserTextBareLineWhenNoContext() {
        XCTAssertEqual(
            visionLookUserText(pageTitle: nil, pageText: nil, direction: nil),
            "Here is what I am looking at.")
        XCTAssertEqual(
            visionLookUserText(pageTitle: "", pageText: "", direction: ""),
            "Here is what I am looking at.")
    }

    func testUserTextCarriesTitleTextAndDirectionAsLines() {
        let text = visionLookUserText(
            pageTitle: "Safari — Dribbble",
            pageText: "iOS banking app concept",
            direction: "the hero card")
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "The user is in: Safari — Dribbble")
        XCTAssertTrue(lines[1].hasPrefix("Visible text near the region"))
        XCTAssertTrue(lines[1].contains("iOS banking app concept"))
        XCTAssertEqual(lines[2], "The user's direction: the hero card")
    }

    func testUserTextTruncatesPageTextAtTwoThousandCharacters() {
        let long = String(repeating: "a", count: 5000)
        let text = visionLookUserText(pageTitle: nil, pageText: long, direction: nil)
        XCTAssertTrue(text.count < 2100)
        XCTAssertTrue(text.contains(String(repeating: "a", count: 2000)))
        XCTAssertFalse(text.contains(String(repeating: "a", count: 2001)))
    }
}

// MARK: - Wire shapes

final class VisionLookWireTests: XCTestCase {

    func testRequestDecodesFromWireJSON() throws {
        let json = """
        {
          "image": "aGVsbG8=",
          "media_type": "image/jpeg",
          "mode": "describe",
          "page_title": "Safari — YouTube",
          "direction": "the video"
        }
        """
        let request = try JSONDecoder().decode(VisionLookRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.image, "aGVsbG8=")
        XCTAssertEqual(request.mediaType, "image/jpeg")
        XCTAssertEqual(request.mode, "describe")
        XCTAssertEqual(request.pageTitle, "Safari — YouTube")
        XCTAssertNil(request.pageText)
        XCTAssertEqual(request.direction, "the video")
        XCTAssertNil(request.authoringContract)
    }

    func testResponseEncodesSingleTextField() throws {
        let data = try JSONEncoder().encode(VisionLookResponse(text: "A hero card."))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(object["text"] as? String, "A hero card.")
    }

    func testVisionChatEncodesPixtralContentParts() throws {
        let request = Requests.VisionChat.Get(
            model: "pixtral-large-latest",
            system: "Look.",
            userText: "Here.",
            imageDataURL: "data:image/jpeg;base64,aGVsbG8=",
            maxTokens: 800)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "pixtral-large-latest")
        XCTAssertEqual(object["max_tokens"] as? Int, 800)

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")

        let userParts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userParts.count, 2)
        XCTAssertEqual(userParts[0]["type"] as? String, "text")
        XCTAssertEqual(userParts[0]["text"] as? String, "Here.")
        XCTAssertEqual(userParts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(userParts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/jpeg;base64,aGVsbG8=")
    }

    func testVisionChatResultDecodesPlainStringContent() throws {
        let json = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":"A card."}}]}
        """
        let result = try JSONDecoder().decode(
            Requests.VisionChat.Get.Result.self, from: Data(json.utf8))
        XCTAssertEqual(result.choices.first?.message.content, "A card.")
    }
}
