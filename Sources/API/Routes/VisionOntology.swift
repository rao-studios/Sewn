//
//  VisionOntology.swift
//  Sewn
//
//  ONE IMAGE IN, ONE ONTOLOGY OUT. A rights registry (ThreadDB's knowledge
//  graph) needs a catalogue card for every image it takes custody of: a
//  caption, tags, the concrete things a rights holder could claim, and how
//  those things relate. The vision model is Mistral's multimodal mainline
//  behind the existing NetworkService, asked for a JSON object and parsed
//  tolerantly the way Thread's GraphExtractionParser reads the same kind of
//  payload. Entity kinds are coerced into Thread's ontology so the graph
//  never learns a kind it did not define. Nothing is stored, streamed, or
//  retained here: one bounded request, one bounded answer.
//
//  Sibling of `/v1/vision/look`: same validation, same wire shape to the
//  model, plus `response_format` — and one retry without it, because a
//  provider that rejects the JSON mode should not take the route down.
//

import Foundation
import Hummingbird
import Logging

// MARK: - Wire models

struct VisionOntologyRequest: Codable {
    let image: String
    let mediaType: String
    let hint: String?

    enum CodingKeys: String, CodingKey {
        case image
        case mediaType = "media_type"
        case hint
    }
}

struct VisionOntologyEntity: Codable, Equatable {
    let name: String
    let kind: String
}

struct VisionOntologyRelationship: Codable, Equatable {
    let subject: String
    let predicate: String
    let object: String
}

struct VisionOntologyResponse: Codable, ResponseEncodable {
    let caption: String
    let tags: [String]
    let entities: [VisionOntologyEntity]
    let relationships: [VisionOntologyRelationship]
    /// The model that actually answered — `ModelConfig.visionModel`.
    let model: String
}

// MARK: - Prompt construction (free functions so tests can pin the wording)

/// The cataloguer's contract. The kind list is Thread's ontology verbatim;
/// the parser coerces anything else to `concept`, so the wording here and
/// `VisionOntologyParser.kinds` must move together.
func visionOntologySystemPrompt() -> String {
    """
    You are an image cataloguer for a rights registry. You are shown ONE image. \
    Reply with ONLY a JSON object — no prose, no code fences — of exactly this shape:
    {"caption": string, "tags": [string], "entities": [{"name": string, "kind": string}], \
    "relationships": [{"subject": string, "predicate": string, "object": string}]}
    caption: one factual sentence (at most 240 characters) naming the subject, setting, style and medium.
    tags: 3 to 12 lowercase noun phrases (subject, style, palette, medium, era).
    entities: up to 12 concrete things a rights holder could claim — recognisable people or characters, \
    brands and organizations, places, events, works (titles, franchises), distinctive concepts. \
    kind is exactly one of: person, organization, place, event, work, concept, other.
    Never invent a real person's name from appearance alone; if you do not recognise the individual, \
    describe the role (for example "woman in red coat") with kind other.
    relationships: up to 15 triples whose subject and object are entity names from your list, \
    with short lowercase predicates (wears, holds, depicts, located in, part of, created by, styled as).
    Output valid JSON only.
    """
}

/// The user message: the bare instruction, plus the uploader's context on a
/// second line when there is one. The route refuses hints over 1000
/// characters; the prefix here is belt-and-braces for any other caller.
func visionOntologyUserText(hint: String?) -> String {
    var lines = ["Catalogue this image."]
    if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
        lines.append("Context from the uploader: \(String(hint.prefix(1000)))")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Tolerant parser

/// Reads the model's answer into a `VisionOntologyResponse`. Accepts bare
/// JSON, fenced JSON, or JSON wrapped in prose (extracts the outermost
/// braces); every field is optional on the way in; kinds outside Thread's
/// ontology coerce to `concept`; counts are capped so a runaway answer
/// cannot flood the graph.
enum VisionOntologyParser {
    static let maxTags = 16
    static let maxEntities = 12
    static let maxRelationships = 15
    static let maxCaption = 400
    static let kinds: Set<String> = [
        "person", "organization", "place", "event", "work", "concept", "other",
    ]

    enum ParseError: Error { case noJSONObject, decodeFailed, emptyCaption }

    /// Optional-everything mirror of the prompt's shape. Elements that are
    /// not the expected shape decode to nil fields and are skipped, rather
    /// than failing the whole answer.
    private struct Raw: Decodable {
        struct Tag: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                value = try? decoder.singleValueContainer().decode(String.self)
            }
        }

        struct Entity: Decodable {
            let name: String?
            let kind: String?

            enum CodingKeys: String, CodingKey { case name, kind }

            init(from decoder: Decoder) throws {
                // A bare string is an entity with no stated kind → concept.
                if let bare = try? decoder.singleValueContainer().decode(String.self) {
                    name = bare
                    kind = nil
                    return
                }
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    name = nil
                    kind = nil
                    return
                }
                name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
                kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
            }
        }

        struct Relation: Decodable {
            let subject: String?
            let predicate: String?
            let object: String?

            enum CodingKeys: String, CodingKey { case subject, predicate, object }

            init(from decoder: Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    subject = nil
                    predicate = nil
                    object = nil
                    return
                }
                subject = (try? container.decodeIfPresent(String.self, forKey: .subject)) ?? nil
                predicate = (try? container.decodeIfPresent(String.self, forKey: .predicate)) ?? nil
                object = (try? container.decodeIfPresent(String.self, forKey: .object)) ?? nil
            }
        }

        let caption: String?
        let tags: [Tag]?
        let entities: [Entity]?
        let relationships: [Relation]?

        enum CodingKeys: String, CodingKey { case caption, tags, entities, relationships }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            caption = (try? container.decodeIfPresent(String.self, forKey: .caption)) ?? nil
            tags = (try? container.decodeIfPresent([Tag].self, forKey: .tags)) ?? nil
            entities = (try? container.decodeIfPresent([Entity].self, forKey: .entities)) ?? nil
            relationships = (try? container.decodeIfPresent([Relation].self, forKey: .relationships)) ?? nil
        }
    }

    static func parse(_ text: String, model: String) throws -> VisionOntologyResponse {
        // Code fences carry no braces of their own, but strip them anyway so
        // a fence marker never lands inside the extracted slice.
        let unfenced = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let first = unfenced.firstIndex(of: "{"),
              let last = unfenced.lastIndex(of: "}"),
              first < last else {
            throw ParseError.noJSONObject
        }
        let slice = String(unfenced[first...last])
        guard let data = slice.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw ParseError.decodeFailed
        }

        // Caption: one sentence, trimmed, bounded, never empty.
        let caption = String(
            (raw.caption ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxCaption))
        guard !caption.isEmpty else { throw ParseError.emptyCaption }

        // Tags: lowercase, deduplicated, capped.
        var tags: [String] = []
        var seenTags = Set<String>()
        for tag in raw.tags ?? [] {
            guard let value = tag.value else { continue }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seenTags.insert(normalized).inserted else { continue }
            tags.append(normalized)
            if tags.count >= maxTags { break }
        }

        // Entities: kind coerced into the ontology, deduplicated on
        // (kind, lowercased name), capped.
        var entities: [VisionOntologyEntity] = []
        var seenEntityKeys = Set<String>()
        var canonicalNames: [String: String] = [:]   // lowercased → as listed
        for entity in raw.entities ?? [] {
            let name = (entity.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var kind = (entity.kind ?? "concept")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !kinds.contains(kind) { kind = "concept" }
            let lowered = name.lowercased()
            guard seenEntityKeys.insert("\(kind)|\(lowered)").inserted else { continue }
            entities.append(VisionOntologyEntity(name: name, kind: kind))
            if canonicalNames[lowered] == nil { canonicalNames[lowered] = name }
            if entities.count >= maxEntities { break }
        }

        // Relationships: both endpoints must name a listed entity
        // (case-insensitively); endpoints are written back as listed so the
        // graph joins exactly. Deduplicated, capped.
        var relationships: [VisionOntologyRelationship] = []
        var seenRelationKeys = Set<String>()
        for relation in raw.relationships ?? [] {
            let subject = (relation.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let object = (relation.object ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = (relation.predicate ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !predicate.isEmpty,
                  let subjectName = canonicalNames[subject.lowercased()],
                  let objectName = canonicalNames[object.lowercased()] else { continue }
            let key = "\(subjectName.lowercased())|\(predicate)|\(objectName.lowercased())"
            guard seenRelationKeys.insert(key).inserted else { continue }
            relationships.append(VisionOntologyRelationship(
                subject: subjectName, predicate: predicate, object: objectName))
            if relationships.count >= maxRelationships { break }
        }

        return VisionOntologyResponse(
            caption: caption,
            tags: tags,
            entities: entities,
            relationships: relationships,
            model: model)
    }
}

// MARK: - Route registration

func registerVisionOntologyRoute(
    _ router: some RouterMethods<SewnRequestContext>
) {
    router.post("/v1/vision/ontology") { request, context async throws -> VisionOntologyResponse in
        let body = try await request.decode(as: VisionOntologyRequest.self, context: context)

        guard !body.image.isEmpty else {
            throw HTTPError(.badRequest, message: "image is required")
        }
        // Base64 of the client's pre-send cap; anything larger is a
        // misbehaving client, refused before the upstream call.
        guard body.image.utf8.count <= 8 * 1024 * 1024 else {
            throw HTTPError(.contentTooLarge, message: "image exceeds the 8 MiB limit")
        }
        guard ["image/jpeg", "image/png"].contains(body.mediaType) else {
            throw HTTPError(.badRequest, message: "media_type must be image/jpeg or image/png")
        }
        if let hint = body.hint, hint.count > 1000 {
            throw HTTPError(.badRequest, message: "hint exceeds 1000 characters")
        }
        let hasHint = !(body.hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        context.logger.info(
            "[VisionOntology] media: \(body.mediaType), image b64 bytes: \(body.image.utf8.count), hint: \(hasHint ? "yes" : "no")"
        )

        let model = ModelConfig.visionModel
        let system = visionOntologySystemPrompt()
        let userText = visionOntologyUserText(hint: body.hint)
        let imageDataURL = "data:\(body.mediaType);base64,\(body.image)"
        let network = NetworkService(logger: context.logger, base: .mistral)

        func ask(
            responseFormat: Requests.VisionOntologyChat.Get.ResponseFormat?
        ) async throws -> Requests.VisionOntologyChat.Get.Result {
            try await network.request(
                Requests.VisionOntologyChat.Get(
                    model: model,
                    system: system,
                    userText: userText,
                    imageDataURL: imageDataURL,
                    responseFormat: responseFormat))
        }

        // JSON mode first; on any upstream failure, once more without it. A
        // missing key is not an upstream failure — it fails before any
        // request leaves the process, and retrying would fail the same way —
        // so it maps straight to 503 the way `/v1/complete` does.
        let response: Requests.VisionOntologyChat.Get.Result
        do {
            response = try await ask(responseFormat: .jsonObject)
        } catch let error as ProviderUnavailable {
            context.logger.error("[VisionOntology] provider unavailable: \(error)")
            throw HTTPError(.serviceUnavailable, message: error.description)
        } catch {
            context.logger.warning("[VisionOntology] upstream failure with response_format, retrying without: \(error)")
            do {
                response = try await ask(responseFormat: nil)
            } catch let error as ProviderUnavailable {
                context.logger.error("[VisionOntology] provider unavailable: \(error)")
                throw HTTPError(.serviceUnavailable, message: error.description)
            } catch {
                context.logger.error("[VisionOntology] upstream failure: \(error)")
                throw HTTPError(.badGateway, message: "vision model unavailable")
            }
        }

        guard let answer = response.choices.first?.message.content,
              !answer.isEmpty else {
            throw HTTPError(.badGateway, message: "vision model returned no answer")
        }

        do {
            return try VisionOntologyParser.parse(answer, model: model)
        } catch {
            context.logger.debug("[VisionOntology] unparsable answer (\(error)): \(String(answer.prefix(300)))")
            throw HTTPError(.badGateway, message: "vision model returned no ontology")
        }
    }
}

// MARK: - Mistral vision request (content parts + response_format)

extension Requests {
    struct VisionOntologyChat {}
}

extension Requests.VisionOntologyChat {
    /// A copy of `Requests.VisionChat.Get`'s content-parts shape with one
    /// addition: an optional `response_format`. Kept apart from the look's
    /// request so the look never grows a JSON mode by accident, and apart
    /// from the plain-string chat wire for the same reason as the look.
    struct Get: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/chat/completions" }
        var method: RequestMethod { .post }

        let model: String
        let messages: [Message]
        let maxTokens: Int?
        let temperature: Double?
        /// `{"type":"json_object"}` when set; omitted from the wire when nil.
        let responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case maxTokens = "max_tokens"
            case temperature
            case responseFormat = "response_format"
        }

        init(
            model: String,
            system: String,
            userText: String,
            imageDataURL: String,
            maxTokens: Int = 900,
            temperature: Float = 0.1,
            responseFormat: ResponseFormat? = nil
        ) {
            self.model = model
            self.messages = [
                Message(role: "system", parts: [.text(system)]),
                Message(
                    role: "user",
                    parts: [.text(userText), .imageURL(imageDataURL)]),
            ]
            self.maxTokens = maxTokens
            self.temperature = Double(temperature)
            self.responseFormat = responseFormat
        }

        struct ResponseFormat: Codable, Equatable {
            let type: String
            static let jsonObject = ResponseFormat(type: "json_object")
        }

        struct Message: Codable {
            let role: String
            let content: [Part]

            init(role: String, parts: [Part]) {
                self.role = role
                self.content = parts
            }
        }

        enum Part: Codable {
            case text(String)
            case imageURL(String)

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }
            struct ImageURL: Codable { let url: String }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .imageURL(let url):
                    try container.encode("image_url", forKey: .type)
                    try container.encode(ImageURL(url: url), forKey: .imageURL)
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                if type == "image_url" {
                    self = .imageURL(try container.decode(ImageURL.self, forKey: .imageURL).url)
                } else {
                    self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
                }
            }
        }

        // Mistral-compatible response: assistant content arrives as a plain
        // string even for vision calls, JSON mode or not.
        struct Result: Codable {
            let choices: [Choice]
        }
        struct Choice: Codable {
            let index: Int
            let message: ResponseMessage
        }
        struct ResponseMessage: Codable {
            let role: String
            let content: String
        }
    }
}
