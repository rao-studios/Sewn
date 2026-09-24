//
//  ChatCompletionResponse.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct ChatCompletionResponse: Codable {
    let id: String
    let object: String = "chat.completion"
    let created: Int
    let model: String
    let choices: [ChatCompletionChoice]
    let usage: CompletionUsage
    let systemFingerprint: String? = nil
    var serviceTier: String? = "default"
    let references: [Sewn.DocumentReference]
    let contribution: Gita.Contribution?
    let autoMemory: Bool
    let tone: SinatraTone?
    /// Personality id that served this response, when one was selected.
    let personality: String?
    /// What SinatraMLX did on an on-device turn.
    let sinatra: LocalSinatraDiagnostics?

    init(
        id: String = "chatcmpl-\(UUID().uuidString)",
        created: Int = Int(
            Date().timeIntervalSince1970
        ),
        model: String,
        choices: [ChatCompletionChoice],
        usage: CompletionUsage,
        serviceTier: String? = "default",
        references: [Sewn.DocumentReference] = [],
        contribution: Gita.Contribution? = nil,
        autoMemory: Bool = false,
        tone: SinatraTone? = nil,
        personality: String? = nil,
        sinatra: LocalSinatraDiagnostics? = nil
    ) {
        self.sinatra = sinatra
        self.id = id
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.serviceTier = serviceTier
        self.references = references
        self.contribution = contribution
        self.autoMemory = autoMemory
        self.tone = tone
        self.personality = personality
    }

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case systemFingerprint = "system_fingerprint"
        case serviceTier = "service_tier"
        case references
        case contribution
        case autoMemory = "auto_memory"
        case tone
        case personality
        case sinatra
    }
}

struct ChatCompletionChoice: Codable {
    let index: Int
    let message: ChatMessageResponseData
    let logprobs: String? = nil
    let finishReason: String

    enum CodingKeys: String, CodingKey {
        case index, message, logprobs
        case finishReason = "finish_reason"
    }
}
