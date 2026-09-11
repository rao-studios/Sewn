//
//  CompletionsRequest.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

struct CompletionRequest: Codable {
    let model: String?
    let prompt: String
    let maxTokens: Int?
    let temperature: Float?
    let topP: Float?
    let n: Int?
    let stream: Bool?
    let logprobs: Int?
    let stop: [String]?
    let repetitionPenalty: Float?
    let repetitionContextSize: Int?
    let kvBits: Int?
    let kvGroupSize: Int?
    let quantizedKVStart: Int?

    enum CodingKeys: String, CodingKey {
        case model, prompt, temperature, n, stream, logprobs, stop
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case repetitionPenalty = "repetition_penalty"
        case repetitionContextSize = "repetition_context_size"
        case kvBits = "kv_bits"
        case kvGroupSize = "kv_group_size"
        case quantizedKVStart = "quantized_kv_start"
    }
}

struct ContentFragment: Codable {
    let type: String
    let text: String?
    let imageUrl: URL?
    let videoUrl: URL?
    
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
        case videoUrl = "video_url"
    }
}
