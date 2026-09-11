//
//  ChatCompletionDelta.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct ChatCompletionDelta: Codable {
    var role: String?
    var content: String?
}

struct ChatCompletionChoiceDelta: Codable {
    let index: Int
    let delta: ChatCompletionDelta
    let logprobs: String? = nil
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta, logprobs
        case finishReason = "finish_reason"
    }
}
