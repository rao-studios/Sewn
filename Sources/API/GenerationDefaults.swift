//
//  Generation.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation

enum GenerationDefaults {
    static let maxTokens = 128
    static let temperature: Float = 0.8
    static let topP: Float = 1.0
    static let stream = false
    static let repetitionPenalty: Float = 1.0
    static let repetitionContextSize = 20
    static let stopSequences: [String] = []

    static let kvGroupSize: Int = 64
    static let quantizedKVStart: Int = 0
}

struct StopCondition {
    let stopMet: Bool
    let trimLength: Int
}

func checkStoppingCriteria(tokens: [Int], stopIdSequences: [[Int]], eosTokenId: Int)
    -> StopCondition
{
    guard let lastToken = tokens.last else {
        return StopCondition(stopMet: false, trimLength: 0)
    }

    if lastToken == eosTokenId {
        return StopCondition(stopMet: true, trimLength: 1)
    }

    for stopIds in stopIdSequences {
        guard !stopIds.isEmpty else { continue }
        if tokens.count >= stopIds.count, tokens.suffix(stopIds.count) == stopIds {
            return StopCondition(stopMet: true, trimLength: stopIds.count)
        }
    }

    return StopCondition(stopMet: false, trimLength: 0)
}
