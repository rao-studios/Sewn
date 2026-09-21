//
//  VisionOntologyTests.swift
//  sewn-serverTests
//
//  The ontology route's prompt wording, its tolerant parser, and the wire
//  shape it sends Mistral — no network anywhere. The load-bearing pins: the
//  kind list the prompt promises is the kind list the parser enforces, a
//  fenced or prose-wrapped answer still parses, counts are capped, and
//  `response_format` rides only when the route asks for it.
//

import XCTest
@testable import sewn_server

final class VisionOntologyTests: XCTestCase {

    // MARK: - Prompts

    func testSystemPromptDemandsOneJSONObject() {
        let prompt = visionOntologySystemPrompt()
        XCTAssertTrue(prompt.contains("ONLY a JSON object"))
        XCTAssertTrue(prompt.contains("no code fences"))
        XCTAssertTrue(prompt.contains("Output valid JSON only."))
    }

    func testSystemPromptPinsThreadKindListVerbatim() {
        let prompt = visionOntologySystemPrompt()
        XCTAssertTrue(prompt.contains(
            "kind is exactly one of: person, organization, place, event, work, concept, other."))
        // The prompt's list and the parser's set must move together.
        for kind in VisionOntologyParser.kinds {
            XCTAssertTrue(prompt.contains(kind), "prompt omits kind \(kind)")
        }
    }

    func testSystemPromptForbidsGuessingRealNames() {
        let prompt = visionOntologySystemPrompt()
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("with kind other"))
    }

    func testUserTextWithoutHintIsTheBareInstruction() {
        XCTAssertEqual(visionOntologyUserText(hint: nil), "Catalogue this image.")
        XCTAssertEqual(visionOntologyUserText(hint: ""), "Catalogue this image.")
        XCTAssertEqual(visionOntologyUserText(hint: "   \n"), "Catalogue this image.")
    }

    func testUserTextWithHintAddsSecondLine() {
        let text = visionOntologyUserText(hint: "generated fantasy art")
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Catalogue this image.")
        XCTAssertEqual(lines[1], "Context from the uploader: generated fantasy art")
    }

    func testUserTextCapsHintAtOneThousandCharacters() {
        let long = String(repeating: "h", count: 3000)
        let text = visionOntologyUserText(hint: long)
        XCTAssertTrue(text.contains(String(repeating: "h", count: 1000)))
        XCTAssertFalse(text.contains(String(repeating: "h", count: 1001)))
    }

    // MARK: - Parser: shapes it accepts

    private let cleanJSON = """
    {"caption": "A dragon coils over a ruined temple at dusk, painted in a dark fantasy style.",
     "tags": ["Dragon", "fantasy art", "dusk", "ruins"],
     "entities": [{"name": "Bahamut", "kind": "work"}, {"name": "ruined temple", "kind": "place"}],
     "relationships": [{"subject": "Bahamut", "predicate": "located in", "object": "ruined temple"}]}
    """

    func testParsesCleanJSON() throws {
        let result = try VisionOntologyParser.parse(cleanJSON, model: "mistral-medium-latest")
        XCTAssertEqual(result.caption, "A dragon coils over a ruined temple at dusk, painted in a dark fantasy style.")
        XCTAssertEqual(result.tags, ["dragon", "fantasy art", "dusk", "ruins"])
        XCTAssertEqual(result.entities, [
            VisionOntologyEntity(name: "Bahamut", kind: "work"),
            VisionOntologyEntity(name: "ruined temple", kind: "place"),
        ])
        XCTAssertEqual(result.relationships, [
            VisionOntologyRelationship(subject: "Bahamut", predicate: "located in", object: "ruined temple"),
        ])
        XCTAssertEqual(result.model, "mistral-medium-latest")
    }

    func testParsesFencedJSON() throws {
        let fenced = "```json\n\(cleanJSON)\n```"
        let result = try VisionOntologyParser.parse(fenced, model: "m")
        XCTAssertEqual(result.entities.count, 2)
        XCTAssertEqual(result.relationships.count, 1)
    }

    func testParsesProseWrappedJSON() throws {
        let wrapped = "Here is the catalogue entry you asked for:\n\(cleanJSON)\nLet me know if you need more."
        let result = try VisionOntologyParser.parse(wrapped, model: "m")
        XCTAssertEqual(result.tags.count, 4)
        XCTAssertEqual(result.entities.first?.name, "Bahamut")
    }

    func testNoJSONObjectThrows() {
        XCTAssertThrowsError(try VisionOntologyParser.parse("I cannot see an image.", model: "m")) { error in
            guard case VisionOntologyParser.ParseError.noJSONObject = error else {
                return XCTFail("expected noJSONObject, got \(error)")
            }
        }
    }

    func testMalformedJSONThrowsDecodeFailed() {
        // Braces are present, so extraction succeeds; the slice itself is
        // not JSON (an unterminated array), so decoding is what fails.
        XCTAssertThrowsError(try VisionOntologyParser.parse("{\"caption\": \"x\", \"tags\": [}", model: "m")) { error in
            guard case VisionOntologyParser.ParseError.decodeFailed = error else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
        }
    }

    // MARK: - Parser: entities

    func testBareStringEntitiesBecomeConcepts() throws {
        let json = """
        {"caption": "c", "entities": ["chiaroscuro", {"name": "Louvre", "kind": "place"}]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.entities, [
            VisionOntologyEntity(name: "chiaroscuro", kind: "concept"),
            VisionOntologyEntity(name: "Louvre", kind: "place"),
        ])
    }

    func testInvalidKindCoercesToConcept() throws {
        let json = """
        {"caption": "c", "entities": [
            {"name": "Golden Gate Bridge", "kind": "landmark"},
            {"name": "Nike", "kind": "Brand"},
            {"name": "Bowie", "kind": " PERSON "}
        ]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.entities.map(\.kind), ["concept", "concept", "person"])
    }

    func testMissingKindDefaultsToConcept() throws {
        let json = """
        {"caption": "c", "entities": [{"name": "art deco"}]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.entities, [VisionOntologyEntity(name: "art deco", kind: "concept")])
    }

    func testDuplicateEntitiesCollapseOnKindAndLowercasedName() throws {
        let json = """
        {"caption": "c", "entities": [
            {"name": "Bahamut", "kind": "work"},
            {"name": " bahamut ", "kind": "WORK"},
            {"name": "Bahamut", "kind": "person"}
        ]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.entities, [
            VisionOntologyEntity(name: "Bahamut", kind: "work"),
            VisionOntologyEntity(name: "Bahamut", kind: "person"),
        ])
    }

    func testEmptyAndMalformedEntitiesAreSkipped() throws {
        let json = """
        {"caption": "c", "entities": [{"name": "  "}, 42, {"kind": "place"}, {"name": "Paris", "kind": "place"}]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.entities, [VisionOntologyEntity(name: "Paris", kind: "place")])
    }

    func testEntitiesCappedAtTwelve() throws {
        let entities = (1...20).map { "{\"name\": \"entity \($0)\", \"kind\": \"concept\"}" }
        let json = "{\"caption\": \"c\", \"entities\": [\(entities.joined(separator: ","))]}"
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.entities.count, VisionOntologyParser.maxEntities)
        XCTAssertEqual(result.entities.count, 12)
        XCTAssertEqual(result.entities.last?.name, "entity 12")
    }

    // MARK: - Parser: relationships

    func testRelationshipWithUnknownEndpointIsDropped() throws {
        let json = """
        {"caption": "c",
         "entities": [{"name": "Bahamut", "kind": "work"}, {"name": "temple", "kind": "place"}],
         "relationships": [
            {"subject": "Bahamut", "predicate": "located in", "object": "temple"},
            {"subject": "Bahamut", "predicate": "created by", "object": "Unknown Artist"},
            {"subject": "Nobody", "predicate": "holds", "object": "temple"}
         ]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.relationships, [
            VisionOntologyRelationship(subject: "Bahamut", predicate: "located in", object: "temple"),
        ])
    }

    func testRelationshipEndpointsMatchCaseInsensitivelyAndCanonicalize() throws {
        let json = """
        {"caption": "c",
         "entities": [{"name": "Bahamut", "kind": "work"}, {"name": "Temple", "kind": "place"}],
         "relationships": [{"subject": " bahamut ", "predicate": " Located In ", "object": "TEMPLE"}]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.relationships, [
            VisionOntologyRelationship(subject: "Bahamut", predicate: "located in", object: "Temple"),
        ])
    }

    func testRelationshipsWithoutPredicateOrEndpointsAreSkipped() throws {
        let json = """
        {"caption": "c",
         "entities": [{"name": "A", "kind": "work"}, {"name": "B", "kind": "place"}],
         "relationships": [{"subject": "A", "predicate": "", "object": "B"}, {"subject": "A"}, "A holds B"]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertTrue(result.relationships.isEmpty)
    }

    func testRelationshipsCappedAtFifteen() throws {
        let entities = (1...12).map { "{\"name\": \"e\($0)\", \"kind\": \"concept\"}" }
        var relations: [String] = []
        for i in 1...12 {
            for j in 1...12 where i != j {
                relations.append("{\"subject\": \"e\(i)\", \"predicate\": \"near\", \"object\": \"e\(j)\"}")
            }
        }
        let json = """
        {"caption": "c", "entities": [\(entities.joined(separator: ","))],
         "relationships": [\(relations.joined(separator: ","))]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.relationships.count, VisionOntologyParser.maxRelationships)
        XCTAssertEqual(result.relationships.count, 15)
    }

    // MARK: - Parser: tags and caption

    func testTagsAreLowercasedTrimmedAndDeduplicated() throws {
        let json = """
        {"caption": "c", "tags": ["Dragon", " dragon ", "DRAGON", "fantasy art", "", 7, "fantasy art"]}
        """
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.tags, ["dragon", "fantasy art"])
    }

    func testTagsCappedAtSixteen() throws {
        let tags = (1...30).map { "\"tag \($0)\"" }
        let json = "{\"caption\": \"c\", \"tags\": [\(tags.joined(separator: ","))]}"
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.tags.count, VisionOntologyParser.maxTags)
        XCTAssertEqual(result.tags.count, 16)
        XCTAssertEqual(result.tags.last, "tag 16")
    }

    func testCaptionIsTrimmedAndCappedAtFourHundred() throws {
        let long = String(repeating: "x", count: 1000)
        let json = "{\"caption\": \"  \(long)  \"}"
        let result = try VisionOntologyParser.parse(json, model: "m")
        XCTAssertEqual(result.caption.count, VisionOntologyParser.maxCaption)
        XCTAssertEqual(result.caption.count, 400)
        XCTAssertEqual(result.caption, String(repeating: "x", count: 400))
    }

    func testEmptyCaptionThrows() {
        for json in ["{\"tags\": [\"a\"]}", "{\"caption\": \"\"}", "{\"caption\": \"   \"}", "{\"caption\": null}"] {
            XCTAssertThrowsError(try VisionOntologyParser.parse(json, model: "m"), json) { error in
                guard case VisionOntologyParser.ParseError.emptyCaption = error else {
                    return XCTFail("expected emptyCaption for \(json), got \(error)")
                }
            }
        }
    }

    func testMissingCollectionsDecodeAsEmpty() throws {
        let result = try VisionOntologyParser.parse("{\"caption\": \"Only a caption.\"}", model: "m")
        XCTAssertEqual(result.caption, "Only a caption.")
        XCTAssertTrue(result.tags.isEmpty)
        XCTAssertTrue(result.entities.isEmpty)
        XCTAssertTrue(result.relationships.isEmpty)
    }

    // MARK: - Wire shapes

    func testRequestDecodesFromWireJSON() throws {
        let json = """
        {"image": "aGVsbG8=", "media_type": "image/png", "hint": "generated fantasy art"}
        """
        let request = try JSONDecoder().decode(VisionOntologyRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.image, "aGVsbG8=")
        XCTAssertEqual(request.mediaType, "image/png")
        XCTAssertEqual(request.hint, "generated fantasy art")

        let bare = try JSONDecoder().decode(
            VisionOntologyRequest.self, from: Data("{\"image\": \"aGVsbG8=\", \"media_type\": \"image/jpeg\"}".utf8))
        XCTAssertNil(bare.hint)
    }

    func testResponseEncodesFlatSnakeCaseFields() throws {
        let response = VisionOntologyResponse(
            caption: "A card.",
            tags: ["card"],
            entities: [VisionOntologyEntity(name: "Card", kind: "work")],
            relationships: [VisionOntologyRelationship(subject: "Card", predicate: "depicts", object: "Card")],
            model: "mistral-medium-latest")
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["caption", "tags", "entities", "relationships", "model"])
        XCTAssertEqual(object["model"] as? String, "mistral-medium-latest")
        let entities = try XCTUnwrap(object["entities"] as? [[String: Any]])
        XCTAssertEqual(entities.first?["kind"] as? String, "work")
    }

    func testChatRequestEncodesResponseFormatWhenSet() throws {
        let request = Requests.VisionOntologyChat.Get(
            model: "mistral-medium-latest",
            system: "Catalogue.",
            userText: "Catalogue this image.",
            imageDataURL: "data:image/png;base64,aGVsbG8=",
            responseFormat: .jsonObject)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let format = try XCTUnwrap(object["response_format"] as? [String: Any])
        XCTAssertEqual(format as? [String: String], ["type": "json_object"])
        XCTAssertEqual(object["model"] as? String, "mistral-medium-latest")
        XCTAssertEqual(object["max_tokens"] as? Int, 900)
        XCTAssertEqual(try XCTUnwrap(object["temperature"] as? Double), 0.1, accuracy: 0.0001)

        // The wire path goes through RawRequest.data, not JSONEncoder — pin
        // that too so a DictionaryEncoder quirk cannot drop the field.
        let wire = request.data
        XCTAssertEqual(wire["response_format"] as? [String: String], ["type": "json_object"])
    }

    func testChatRequestOmitsResponseFormatWhenNil() throws {
        let request = Requests.VisionOntologyChat.Get(
            model: "mistral-medium-latest",
            system: "Catalogue.",
            userText: "Catalogue this image.",
            imageDataURL: "data:image/png;base64,aGVsbG8=")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["response_format"])
        XCTAssertFalse(object.keys.contains("response_format"))

        let wire = request.data
        XCTAssertFalse(wire.keys.contains("response_format"))
    }

    func testChatRequestCarriesImageURLPartWithPNGDataURI() throws {
        let request = Requests.VisionOntologyChat.Get(
            model: "mistral-medium-latest",
            system: "Catalogue.",
            userText: "Catalogue this image.",
            imageDataURL: "data:image/png;base64,aGVsbG8=",
            responseFormat: .jsonObject)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")

        let userParts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userParts.count, 2)
        XCTAssertEqual(userParts[0]["type"] as? String, "text")
        XCTAssertEqual(userParts[0]["text"] as? String, "Catalogue this image.")
        XCTAssertEqual(userParts[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(userParts[1]["image_url"] as? [String: Any])
        let url = try XCTUnwrap(imageURL["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
    }

    func testChatResultDecodesPlainStringContent() throws {
        let json = """
        {"choices":[{"index":0,"message":{"role":"assistant","content":"{\\"caption\\":\\"c\\"}"}}]}
        """
        let result = try JSONDecoder().decode(
            Requests.VisionOntologyChat.Get.Result.self, from: Data(json.utf8))
        XCTAssertEqual(result.choices.first?.message.content, "{\"caption\":\"c\"}")
    }
}
