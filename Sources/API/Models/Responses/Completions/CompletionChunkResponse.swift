//
//  CompletionChunkResponse.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct CompletionChunkResponse: Codable {
    let id: String
    let object: String = "text_completion"
    let created: Int
    let choices: [Choice]
    let model: String
    let systemFingerprint: String

    struct Choice: Codable {
        let text: String
        let index: Int = 0
        var logprobs: String?
        var finishReason: String?

         enum CodingKeys: String, CodingKey {
            case text, index, logprobs
            case finishReason = "finish_reason"
        }
    }

    init(completionId: String, requestedModel: String, nextChunk: String, systemFingerprint: String = "fp_\(UUID().uuidString)") {
        self.id = completionId
        self.created = Int(Date().timeIntervalSince1970)
        self.choices = [Choice(text: nextChunk)]
        self.model = requestedModel
        self.systemFingerprint = systemFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices
        case systemFingerprint = "system_fingerprint"
    }
}
