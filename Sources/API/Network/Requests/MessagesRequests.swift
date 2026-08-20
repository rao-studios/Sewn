//
//  MessagesRequests.swift
//  Seer
//
//  Anthropic-compatible Messages API wire types (ThinkingMachines / Tinker).
//

import Foundation

/// Minimal JSON value for tool schemas and tool_use inputs — lets Encodable
/// requests carry arbitrary JSON without loosening the whole request to [String: Any].
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(
                codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        case .null:          try c.encodeNil()
        }
    }
}

// Literal conformances so tool schemas read like JSON at the call site.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension Requests {
    struct Messages {}
}

extension Requests.Messages {
    struct Create: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/messages" }
        var method: RequestMethod { .post }

        let model: String
        let system: String?
        let messages: [Message]
        let maxTokens: Int
        let temperature: Double?
        let topP: Double?
        let stream: Bool?
        let stopSequences: [String]?
        let tools: [Tool]?
        let toolChoice: ToolChoice?

        enum CodingKeys: String, CodingKey {
            case model
            case system
            case messages
            case maxTokens = "max_tokens"
            case temperature
            case topP = "top_p"
            case stream
            case stopSequences = "stop_sequences"
            case tools
            case toolChoice = "tool_choice"
        }

        init(
            model: String,
            system: String? = nil,
            messages: [Message],
            maxTokens: Int,
            temperature: Float? = nil,
            topP: Float? = nil,
            stream: Bool = false,
            stopSequences: [String]? = nil,
            tools: [Tool]? = nil,
            toolChoice: ToolChoice? = nil
        ) {
            self.model = model
            self.system = system
            self.messages = messages
            self.maxTokens = maxTokens
            self.temperature = temperature.map(Double.init)
            self.topP = topP.map(Double.init)
            self.stream = stream ? true : nil
            self.stopSequences = stopSequences
            self.tools = tools
            self.toolChoice = toolChoice
        }

        struct Message: Codable {
            let role: String   // "user" | "assistant"
            let content: String
        }

        struct Tool: Codable {
            let name: String
            let description: String?
            let inputSchema: JSONValue

            enum CodingKeys: String, CodingKey {
                case name
                case description
                case inputSchema = "input_schema"
            }
        }

        struct ToolChoice: Codable {
            let type: String    // "auto" | "any" | "tool" | "none"
            let name: String?

            static func tool(_ name: String) -> ToolChoice { .init(type: "tool", name: name) }
            static let auto = ToolChoice(type: "auto", name: nil)
        }

        // MARK: Response model (Anthropic Messages)

        struct Result: Codable {
            let id: String
            let model: String
            let role: String
            let content: [ContentBlock]
            let stopReason: String?
            let usage: Usage

            enum CodingKeys: String, CodingKey {
                case id, model, role, content
                case stopReason = "stop_reason"
                case usage
            }

            /// Concatenated text blocks (thinking blocks excluded).
            var text: String {
                content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
            }

            /// First tool_use block, if the model called a tool.
            var toolUse: ContentBlock? {
                content.first { $0.type == "tool_use" }
            }
        }

        struct ContentBlock: Codable {
            let type: String            // "text" | "thinking" | "tool_use"
            let text: String?
            let thinking: String?
            let id: String?             // tool_use id
            let name: String?           // tool_use name
            let input: JSONValue?       // tool_use input
        }

        struct Usage: Codable {
            let inputTokens: Int
            let outputTokens: Int

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }

            /// Bridges to the Mistral-shaped usage the rest of Seer accounts with.
            var asChatUsage: Requests.Chat.Get.Usage {
                .init(promptTokens: inputTokens,
                      completionTokens: outputTokens,
                      totalTokens: inputTokens + outputTokens)
            }
        }
    }
}

// MARK: - Streaming event payloads (Anthropic SSE)

extension Requests.Messages {
    /// Decoded per-event payloads for the Anthropic SSE stream. Events arrive as
    /// `event: <type>\ndata: <json>` frames; consumers switch on `type`.
    struct StreamEvent: Decodable {
        let type: String
        let delta: Delta?
        let usage: Create.Usage?
        let message: MessageStart?

        struct Delta: Decodable {
            let type: String?           // "text_delta" | "input_json_delta"
            let text: String?
            let partialJson: String?
            let stopReason: String?     // present on message_delta

            enum CodingKeys: String, CodingKey {
                case type, text
                case partialJson = "partial_json"
                case stopReason = "stop_reason"
            }
        }

        struct MessageStart: Decodable {
            let id: String?
            let model: String?
            let usage: Create.Usage?
        }
    }
}
