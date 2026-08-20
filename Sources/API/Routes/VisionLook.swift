//
//  VisionLook.swift
//  Seer
//
//  ONE LOOK AT WHAT THE USER IS SEEING. Bonnie captures the region of the
//  screen the user is attending to — a page in any browser, an image, a
//  video frame, a document, any app — and asks this route to either
//  describe it (conversational commentary) or compose a Design Plan that
//  recreates it — the answer text is Bonnie's to relay or execute. The
//  vision model is Mistral's Pixtral behind the existing NetworkService;
//  nothing is stored, streamed, or retained here: one bounded request,
//  one bounded answer.
//

import Foundation
import Hummingbird
import Logging

// MARK: - Wire models

struct VisionLookRequest: Codable {
    let image: String
    let mediaType: String
    let mode: String
    let pageTitle: String?
    let pageText: String?
    let direction: String?
    let authoringContract: String?

    enum CodingKeys: String, CodingKey {
        case image
        case mediaType = "media_type"
        case mode
        case pageTitle = "page_title"
        case pageText = "page_text"
        case direction
        case authoringContract = "authoring_contract"
    }
}

struct VisionLookResponse: Codable, ResponseEncodable {
    let text: String
}

// MARK: - Prompt construction (free functions so tests can pin the wording)

/// The system prompt per mode. `describe` is screen-scoped — the look works
/// anywhere on the computer; a browser page is just one case.
func visionLookSystemPrompt(mode: String, authoringContract: String?) -> String {
    switch mode {
    case "design_plan":
        return """
        You are a precise UI recreation engine. You are shown one screenshot of a \
        user interface design. Reply with ONLY a JSON array of design commands that \
        recreates it — no prose, no code fences, no explanation. Recreate structure, \
        geometry, text content, fills, and typography as faithfully as the command \
        vocabulary allows. The complete authoring contract for the commands you may \
        emit follows; obey it exactly:

        \(authoringContract ?? "")
        """
    default:
        return """
        You are looking at exactly what the user sees on their screen right now — \
        one region around their attention, captured this moment. Describe it \
        conversationally and concretely: what it is, what stands out, any text \
        worth noting — in at most 1200 characters. When it is a design or an \
        interface, speak as one designer to another — layout, hierarchy, type, \
        color, what works and what doesn't. No preamble; you are both looking \
        at the same thing.
        """
    }
}

/// The user message: the capture's context lines, or an honest bare line.
func visionLookUserText(pageTitle: String?, pageText: String?, direction: String?) -> String {
    var contextLines: [String] = []
    if let title = pageTitle, !title.isEmpty {
        contextLines.append("The user is in: \(title)")
    }
    if let text = pageText, !text.isEmpty {
        contextLines.append("Visible text near the region (may be partial): \(String(text.prefix(2000)))")
    }
    if let direction, !direction.isEmpty {
        contextLines.append("The user's direction: \(direction)")
    }
    return contextLines.isEmpty
        ? "Here is what I am looking at."
        : contextLines.joined(separator: "\n")
}

// MARK: - Route registration

func registerVisionLookRoute(
    _ router: some RouterMethods<SeerRequestContext>
) {
    router.post("/v1/vision/look") { request, context async throws -> VisionLookResponse in
        let look = try await request.decode(as: VisionLookRequest.self, context: context)

        guard !look.image.isEmpty else {
            throw HTTPError(.badRequest, message: "image is required")
        }
        // Base64 of the client's ≤6 MiB pre-send cap; anything larger is a
        // misbehaving client, refused before the upstream call.
        guard look.image.utf8.count <= 8 * 1024 * 1024 else {
            throw HTTPError(.contentTooLarge, message: "image exceeds the 8 MiB limit")
        }
        guard ["image/jpeg", "image/png"].contains(look.mediaType) else {
            throw HTTPError(.badRequest, message: "media_type must be image/jpeg or image/png")
        }
        guard ["describe", "design_plan"].contains(look.mode) else {
            throw HTTPError(.badRequest, message: "mode must be describe or design_plan")
        }
        if look.mode == "design_plan" {
            guard let contract = look.authoringContract, !contract.isEmpty else {
                throw HTTPError(.badRequest, message: "design_plan requires authoring_contract")
            }
            guard contract.utf8.count <= 16_384 else {
                throw HTTPError(.badRequest, message: "authoring_contract exceeds 16 KiB")
            }
        }

        context.logger.info("[VisionLook] mode: \(look.mode), media: \(look.mediaType), image b64 bytes: \(look.image.utf8.count)")

        let system = visionLookSystemPrompt(
            mode: look.mode, authoringContract: look.authoringContract)
        let userText = visionLookUserText(
            pageTitle: look.pageTitle, pageText: look.pageText, direction: look.direction)

        let network = NetworkService(logger: context.logger, base: .mistral)
        let response: Requests.VisionChat.Get.Result
        do {
            response = try await network.request(
                Requests.VisionChat.Get(
                    model: ModelConfig.visionModel,
                    system: system,
                    userText: userText,
                    imageDataURL: "data:\(look.mediaType);base64,\(look.image)",
                    maxTokens: look.mode == "design_plan" ? 4096 : 800))
        } catch {
            context.logger.error("[VisionLook] upstream failure: \(error)")
            throw HTTPError(.badGateway, message: "vision model unavailable")
        }

        guard let answer = response.choices.first?.message.content,
              !answer.isEmpty else {
            throw HTTPError(.badGateway, message: "vision model returned no answer")
        }
        return VisionLookResponse(text: answer)
    }
}

// MARK: - Mistral vision request (content parts)

extension Requests {
    struct VisionChat {}
}

extension Requests.VisionChat {
    /// A chat-completions call whose one user message carries content PARTS
    /// (text + image), the Pixtral shape. Kept separate from
    /// `Requests.Chat.Get` so the plain-string chat wire never grows an
    /// image channel by accident.
    struct Get: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/chat/completions" }
        var method: RequestMethod { .post }

        let model: String
        let messages: [Message]
        let maxTokens: Int?
        let temperature: Double?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case maxTokens = "max_tokens"
            case temperature
        }

        init(
            model: String,
            system: String,
            userText: String,
            imageDataURL: String,
            maxTokens: Int,
            temperature: Float = 0.2
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
        // string even for vision calls.
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
