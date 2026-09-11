//
//  ChatResponseContext.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/28/25.
//

import Foundation

struct ChatResponseContext {
    let loadedModelName: String
    let stopIdSequences: [[Int]]
    // let detokenizer: NaiveStreamingDetokenizer
    let estimatedPromptTokens: Int
}
