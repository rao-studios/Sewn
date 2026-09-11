//
//  CompletionChoice.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct CompletionChoice: Codable {
    let text: String
    let index: Int
    let logprobs: [String: Double]?
    let finishReason: String?

    init(text: String, index: Int = 0, logprobs: [String: Double]? = nil, finishReason: String?) {
        self.text = text
        self.index = index
        self.logprobs = logprobs
        self.finishReason = finishReason
    }

     enum CodingKeys: String, CodingKey {
        case text, index, logprobs
        case finishReason = "finish_reason"
    }
}
