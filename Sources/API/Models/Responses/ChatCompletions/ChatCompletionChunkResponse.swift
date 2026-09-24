//
//  ChatCompletionChunkResponse.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct ChatCompletionChunkResponse: Codable {
    let id: String
    let object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let systemFingerprint: String?
    let choices: [ChatCompletionChoiceDelta]
    let references: [Sewn.DocumentReference]
    let contribution: Gita.Contribution?
    let autoMemory: Bool
    /// Personality id serving this stream — set on the first chunk only.
    let personality: String?
    /// What SinatraMLX did on an on-device turn — the trailing metadata chunk only.
    let sinatra: LocalSinatraDiagnostics?

    init(
        id: String,
        created: Int = Int(
            Date().timeIntervalSince1970
        ),
        model: String,
        systemFingerprint: String? = nil,
        choices: [ChatCompletionChoiceDelta],
        references: [Sewn.DocumentReference],
        contribution: Gita.Contribution? = nil,
        autoMemory: Bool = false,
        personality: String? = nil,
        sinatra: LocalSinatraDiagnostics? = nil
    ) {
        self.sinatra = sinatra
        self.id = id
        self.created = created
        self.model = model
        self.systemFingerprint = systemFingerprint
        self.choices = choices
        self.references = references
        self.contribution = contribution
        self.autoMemory = autoMemory
        self.personality = personality
    }

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices
        case systemFingerprint = "system_fingerprint"
        case references
        case contribution
        case autoMemory = "auto_memory"
        case personality
        case sinatra
    }
}
