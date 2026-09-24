//
//  LocalTurn.swift
//  sewn-server
//
//  WHAT: What a chat turn tells the on-device provider beyond its messages: who it
//        belongs to, the user's message that labels the previous turn, the sampling
//        settings, and the per-request SinatraMLX options — plus the diagnostics that
//        come back. Plain types, built on every platform; only the macOS
//        `LocalInference` turns them into SinatraMLX calls.
//

import Foundation

/// The turn context for SinatraMLX. Hosted providers never see it.
struct LocalTurnContext: Sendable {
    let owner: String
    /// This turn's user message — the reply that labels the previous assistant turn.
    let userMessageText: String
    let userMessageAt: Date
    let conversationId: String?
    let options: SinatraRequestOptions?

    static func make(
        owner: String?, request: ChatCompletionRequest, userMessageAt: Date
    ) -> LocalTurnContext? {
        guard let owner, !owner.isEmpty,
            let text = request.messages.last(where: { $0.role == .user })?.content.asString
        else { return nil }
        return LocalTurnContext(
            owner: owner.lowercased(), userMessageText: text, userMessageAt: userMessageAt,
            conversationId: nil, options: request.sinatra)
    }
}

/// The request's optional `sinatra` object: `{mode, trace, seed, record}`.
struct SinatraRequestOptions: Codable, Sendable, Equatable {
    /// "off" | "lexical" | "dense"
    var mode: String?
    /// "automatic" | "off" | "summary" | "full"
    var trace: String?
    /// Fixed sampler seed: reproducible decodes, exact counterfactuals.
    var seed: UInt64?
    /// false: plan and trace without recording the turn (paired comparisons).
    var record: Bool?

    static let modes: Set<String> = ["off", "lexical", "dense"]
    static let traces: Set<String> = ["automatic", "off", "summary", "full"]

    /// A readable reason when a value is not one SinatraMLX knows.
    var validationError: String? {
        if let mode, !Self.modes.contains(mode) { return "sinatra.mode must be one of off, lexical, dense" }
        if let trace, !Self.traces.contains(trace) { return "sinatra.trace must be one of automatic, off, summary, full" }
        return nil
    }
}

/// Sampling for one on-device generation, from the handler's resolved parameters.
struct LocalSampling: Sendable, Equatable {
    var maxTokens: Int
    var temperature: Float
    var topP: Float
    var repetitionPenalty: Float
    var repetitionContextSize: Int
    var kvBits: Int?
    var kvGroupSize: Int
    var quantizedKVStart: Int
    var seed: UInt64?

    init(_ parameters: ChatGenerationParameters, maxTokens: Int, seed: UInt64? = nil) {
        self.maxTokens = maxTokens
        self.temperature = parameters.temperature
        self.topP = parameters.topP
        self.repetitionPenalty = parameters.repetitionPenalty
        self.repetitionContextSize = parameters.repetitionContextSize
        self.kvBits = parameters.kvBits
        self.kvGroupSize = parameters.kvGroupSize
        self.quantizedKVStart = parameters.quantizedKVStart
        self.seed = seed
    }

    /// Utility passes (compaction, tools, one-shots): what MLX's generate used before.
    static func utility(maxTokens: Int) -> LocalSampling {
        var sampling = LocalSampling(
            ChatGenerationParameters(
                maxTokens: maxTokens, temperature: 0.6, topP: 1.0,
                repetitionPenalty: GenerationDefaults.repetitionPenalty,
                repetitionContextSize: GenerationDefaults.repetitionContextSize,
                kvBits: nil, kvGroupSize: GenerationDefaults.kvGroupSize,
                quantizedKVStart: GenerationDefaults.quantizedKVStart),
            maxTokens: maxTokens)
        sampling.seed = nil
        return sampling
    }
}

/// What SinatraMLX did on a local turn: the trailing `sinatra` object on the stream,
/// on the non-streaming response, and (as `SinatraStatusInfo`) on `/v1/providers`.
struct LocalSinatraDiagnostics: Codable, Sendable, Equatable {
    var turnId: String
    var mode: String
    var coldStart: Bool
    var partitions: Int
    var weightedPartitions: Int
    var biasTokens: Int
    var biasMaxAbs: Float
    var gate: Float
    /// This message labelled the previous turn with this implicit reward.
    var previousReward: Float?
    var previousReplyKind: String?
    var observations: Int
    var labelled: Int
    var reliability: Float
    var trainedAt: String?
    var trainingScheduled: Bool
    var encodeMs: Double
    var trace: TraceBrief?

    struct TraceBrief: Codable, Sendable, Equatable {
        var traceId: String
        var level: String
        var seed: UInt64?
        var steps: Int
        var meanEntropyPre: Float
        var meanEntropyPost: Float
        var meanEntropyShift: Float
        var totalKl: Float
        var totalGain: Float
        var meanMassIntoMask: Float
        var divergenceRate: Float
        var firstDivergenceStep: Int?
        var flippedArgmaxSteps: Int
        var sampledInMaskShare: Float

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

/// The local row's `sinatra` object on `GET /v1/providers`.
struct SinatraStatusInfo: Codable, Sendable, Equatable {
    var observations: Int
    var labelled: Int
    var trainedAt: String?
    var reliability: Float
    var lastBiasMagnitude: Float
    var store: String?

    enum CodingKeys: String, CodingKey {
        case observations, labelled, reliability, store
        case trainedAt = "trained_at"
        case lastBiasMagnitude = "last_bias_magnitude"
    }
}

enum SinatraDates {
    static func iso(_ date: Date?) -> String? {
        date.map { ISO8601DateFormatter().string(from: $0) }
    }
}
