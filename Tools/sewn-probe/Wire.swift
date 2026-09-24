//
//  Wire.swift
//  sewn-probe
//
//  WHAT: The JSON the probe reads: stream chunks, SinatraMLX diagnostics and traces,
//        provider rows. Mirrors of Sewn's and SinatraMLX's shapes, tolerant of extras.
//

import Foundation

struct Chunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    let choices: [Choice]?
    let sinatra: SinatraDiagnostics?
    let autoMemory: Bool?
    enum CodingKeys: String, CodingKey {
        case choices, sinatra
        case autoMemory = "auto_memory"
    }
}

struct SinatraDiagnostics: Codable {
    struct TraceBrief: Codable {
        let traceId: String
        let level: String
        let seed: UInt64?
        let steps: Int
        let meanEntropyPre: Float
        let meanEntropyPost: Float
        let meanEntropyShift: Float
        let totalKl: Float
        let totalGain: Float
        let meanMassIntoMask: Float
        let divergenceRate: Float
        let firstDivergenceStep: Int?
        let flippedArgmaxSteps: Int
        let sampledInMaskShare: Float
        enum CodingKeys: String, CodingKey {
            case traceId = "trace_id"
            case level, seed, steps
            case meanEntropyPre = "mean_entropy_pre"
            case meanEntropyPost = "mean_entropy_post"
            case meanEntropyShift = "mean_entropy_shift"
            case totalKl = "total_kl"
            case totalGain = "total_gain"
            case meanMassIntoMask = "mean_mass_into_mask"
            case divergenceRate = "divergence_rate"
            case firstDivergenceStep = "first_divergence_step"
            case flippedArgmaxSteps = "flipped_argmax_steps"
            case sampledInMaskShare = "sampled_in_mask_share"
        }
    }
    let turnId: String
    let mode: String
    let coldStart: Bool
    let partitions: Int
    let weightedPartitions: Int
    let biasTokens: Int
    let biasMaxAbs: Float
    let gate: Float
    let previousReward: Float?
    let previousReplyKind: String?
    let observations: Int
    let labelled: Int
    let reliability: Float
    let trainedAt: String?
    let trainingScheduled: Bool
    let encodeMs: Double
    let trace: TraceBrief?
    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case mode
        case coldStart = "cold_start"
        case partitions
        case weightedPartitions = "weighted_partitions"
        case biasTokens = "bias_tokens"
        case biasMaxAbs = "bias_max_abs"
        case gate
        case previousReward = "previous_reward"
        case previousReplyKind = "previous_reply_kind"
        case observations, labelled, reliability
        case trainedAt = "trained_at"
        case trainingScheduled = "training_scheduled"
        case encodeMs = "encode_ms"
        case trace
    }
}

/// SinatraMLX's InjectionTrace as `GET /v1/providers/local/sinatra/traces/{id}` returns it.
struct Trace: Decodable {
    struct Token: Decodable {
        let id: Int
        let text: String?
        let logprob: Float
    }
    struct Step: Decodable {
        let index: Int
        let sampled: Int
        let counterfactual: Int
        let sampledText: String?
        let counterfactualText: String?
        let entropyPre: Float
        let entropyPost: Float
        let kl: Float
        let logprobPre: Float
        let logprobPost: Float
        let rankPre: Int
        let rankPost: Int
        let massIntoMask: Float
        let inMask: Bool
        let topPre: [Token]?
        let topPost: [Token]?
        let movement: [Float]?
        var diverged: Bool { sampled != counterfactual }
        var gain: Float { logprobPost - logprobPre }
    }
    struct Mask: Decodable {
        let tokenIds: [Int]
        let bias: [Float]
        let partitionIds: [String]
        let tokenTexts: [String]?
    }
    struct Summary: Decodable {
        let steps: Int
        let meanEntropyPre: Float
        let meanEntropyPost: Float
        let meanEntropyShift: Float
        let totalKL: Float
        let totalGain: Float
        let divergenceRate: Float
        let firstDivergenceStep: Int?
        let partitionAttribution: [String: Float]
    }
    let traceId: String
    let level: String
    let mode: String
    let seed: UInt64?
    let mask: Mask?
    let steps: [Step]
    let summary: Summary
}

struct ProvidersPayload: Decodable {
    struct Row: Decodable {
        struct Status: Decodable {
            let observations: Int?
            let labelled: Int?
            let trainedAt: String?
            let reliability: Double?
            let lastBiasMagnitude: Double?
            let store: String?
            enum CodingKeys: String, CodingKey {
                case observations, labelled, reliability, store
                case trainedAt = "trained_at"
                case lastBiasMagnitude = "last_bias_magnitude"
            }
        }
        let id: String
        let available: Bool
        let state: String
        let progress: Double?
        let model: String
        let reason: String?
        let sinatra: Status?
        let isDefault: Bool?
        enum CodingKeys: String, CodingKey {
            case id, available, state, progress, model, reason, sinatra
            case isDefault = "default"
        }
    }
    let providers: [Row]
    let `default`: String
}
