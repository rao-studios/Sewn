//
//  Personality.swift
//  seer-server
//
//  Named chat personas: a voice fragment injected into the system prompt,
//  optional generation-parameter defaults, and an optional fine-tuned
//  `tinker://` model override. Personalities are orthogonal to (but reinforce)
//  the citation-marker protocol that powers exact contribution tracking.
//

import Foundation
import Logging

struct Personality: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var tagline: String
    /// The persona's voice — injected into the conversational-instructions slot
    /// of the chat system prompt.
    var systemFragment: String
    /// When true, a stronger citation-marker reminder is appended to the
    /// context protocol (useful while a base model is still learning the discipline).
    var citationEmphasis: Bool
    var temperature: Float?
    var topP: Float?
    /// Fine-tuned model serving this personality (`tinker://…` sampler path).
    /// Nil → the globally configured chat model.
    var modelOverride: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case tagline
        case systemFragment = "system_fragment"
        case citationEmphasis = "citation_emphasis"
        case temperature
        case topP = "top_p"
        case modelOverride = "model_override"
    }
}

extension Personality {
    static let defaults: [Personality] = [
        Personality(
            id: "seer",
            name: "Seer",
            tagline: "The classic confidante",
            systemFragment: "You are a close confidante — honest, warm, and direct. Offer your honest perspective, not just a reflection of what they already said.",
            citationEmphasis: false,
            temperature: nil,
            topP: nil,
            modelOverride: nil
        ),
        Personality(
            id: "scholar",
            name: "Scholar",
            tagline: "Precise and citation-forward",
            systemFragment: "You are a meticulous research companion. Every claim you make should be traceable to the retrieved sources — favor precision over flourish, quote sparingly but exactly, and clearly separate what the sources say from your own reasoning.",
            citationEmphasis: true,
            temperature: 0.3,
            topP: 0.85,
            modelOverride: nil
        ),
        Personality(
            id: "muse",
            name: "Muse",
            tagline: "Creative and associative",
            systemFragment: "You are an imaginative thinking partner. Connect ideas across the retrieved sources in unexpected ways, propose angles the user hasn't considered, and keep the energy generative — but stay anchored to what the sources actually say.",
            citationEmphasis: false,
            temperature: 0.9,
            topP: 0.95,
            modelOverride: nil
        ),
    ]
}

// MARK: - Store

/// Process-wide personality registry: plist-persisted, hot-swappable via
/// `PUT /v1/admin/personalities`, seeded with defaults on first boot.
enum PersonalityStore {
    private static let state = LockedValue<[Personality]?>(nil)
    private static let key = "personalities"

    static var all: [Personality] {
        if let personalities = state.withLock({ $0 }) { return personalities }
        let logger = Logger(label: "seer-personalities")
        let loaded: [Personality] = FilePersistence(key: key, kind: .basic, logger: logger)
            .restore() ?? Personality.defaults
        state.withLock { $0 = loaded }
        return loaded
    }

    static func personality(id: String?) -> Personality? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    static func update(_ personalities: [Personality], logger: Logger) {
        state.withLock { $0 = personalities }
        FilePersistence(key: key, kind: .basic, logger: logger).save(state: personalities)
    }
}

// MARK: - Per-request persona (handleChat prompt section)

struct ResolvedChatPersona: Equatable, Sendable {
    var name: String
    var voice: String
    var citationEmphasis: Bool

    static let `default` = ResolvedChatPersona(
        name: "Seer",
        voice: Personality.defaults[0].systemFragment,
        citationEmphasis: false)
}

/// Inline `persona` wins per field; stored personality fills the rest;
/// otherwise she is Seer.
func resolveChatPersona(inline: ChatPersona?, stored: Personality?) -> ResolvedChatPersona {
    func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
    return ResolvedChatPersona(
        name: trimmed(inline?.name) ?? stored?.name ?? ResolvedChatPersona.default.name,
        voice: trimmed(inline?.voice) ?? stored?.systemFragment ?? ResolvedChatPersona.default.voice,
        citationEmphasis: stored?.citationEmphasis ?? false)
}

/// THE PERSONALITY SECTION of the chat system prompt — name, then voice,
/// then the memory posture. Extracted so tests pin "Your name is Seer"
/// as the default and "Your name is Mary" when a client sends a persona.
func chatPersonaSection(
    _ persona: ResolvedChatPersona,
    memoryInstruction: String
) -> String {
    """
    Your name is \(persona.name).

    \(persona.voice) \(memoryInstruction)
    """
}
