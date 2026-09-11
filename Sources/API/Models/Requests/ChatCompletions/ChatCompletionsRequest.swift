//
//  ChatCompletionsRequest.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct ChatCompletionRequest: Codable {
    let messages: [ChatMessageRequestData]
    let model: String?
    let maxTokens: Int?
    let temperature: Float?
    let topP: Float?
    let stream: Bool?
    let stop: [String]?
    let repetitionPenalty: Float?
    let repetitionContextSize: Int?
    let resize: [CGFloat]?
    let kvBits: Int?
    let kvGroupSize: Int?
    let quantizedKVStart: Int?
    var instructions: String?
    /// Personality id serving this chat (see `PersonalityStore`).
    var personality: String?
    /// Per-request identity. Lets a client (Mary) name herself and supply
    /// the desired voice without looking up a stored personality. Empty
    /// fields fall through to `personality`, then to "Sewn".
    var persona: ChatPersona? = nil
    // Toggles query expansion
    var resonate: Bool?
    var debug: Bool?
    /// Which client is speaking — "bonnie" switches retrieved context to
    /// SUPPORT framing (background that helps the current request) instead of
    /// primary conversational material, and gives the client's own tool-action
    /// deposits their own tier. Nil/anything else = classic framing.
    var client: String?
    /// WHICH BACKEND ANSWERS THIS TURN. Absent = the server default
    /// (`SEWN_GLOBAL_LLM`), so a client that never heard of providers is
    /// unaffected. Rides the realtime `turn.start` frame too — it wraps this
    /// same request.
    var provider: LLMProvider?

    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case messages, model, temperature, stream, stop, resize, sewn, resonate, instructions, debug, client, provider
        case personality, persona
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case repetitionPenalty = "repetition_penalty"
        case repetitionContextSize = "repetition_context_size"
        case kvBits = "kv_bits"
        case kvGroupSize = "kv_group_size"
        case quantizedKVStart = "quantized_kv_start"
    }
}

/// Inline name and desired voice for one chat turn. Orthogonal to the
/// stored `personality` id: this is what the client calls herself, not a
/// catalog lookup.
struct ChatPersona: Codable, Equatable, Sendable {
    var name: String?
    /// The desired persona — injected where a stored personality's
    /// `systemFragment` would go.
    var voice: String?
}

enum ChatMessageRequestRole: String, Codable {
    case user, assistant, system
}

struct ChatMessageRequestData: Codable {
    let role: ChatMessageRequestRole
    let content: ContentFragmentType
    let timestamp: Date?
    
    enum ContentFragmentType: Codable {
        case text(String)
        case fragments([ContentFragment])
        case none
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            
            if let string = try? container.decode(String.self) {
                self = .text(string)
            } else if let fragments = try? container.decode([ContentFragment].self) {
                self = .fragments(fragments)
            } else if container.decodeNil() {
                self = .none
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected String, [ContentFragment], or nil"
                )
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            
            switch self {
            case .text(let string):
                try container.encode(string)
            case .fragments(let fragments):
                try container.encode(fragments)
            case .none:
                try container.encodeNil()
            }
        }
        
        var asString: String? {
            switch self {
            case .text(let string):
                return string
            case .fragments(let fragments):
                let textFragments = fragments.compactMap { $0.type == "text" ? $0.text : nil }
                return textFragments.isEmpty ? nil : textFragments.joined()
            case .none:
                return nil
            }
        }
    }
}
