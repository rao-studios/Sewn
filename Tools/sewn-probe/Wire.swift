//
//  Wire.swift
//  sewn-probe
//
//  WHAT: The JSON the probe reads: stream chunks, SinatraHarness diagnostics and traces,
//        provider rows. Mirrors of Sewn's and SinatraHarness's shapes, tolerant of extras.
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

/// A generation that failed after the stream began.
struct StreamFailure: Decodable {
    struct Detail: Decodable { let message: String? }
    let error: Detail
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
    let observations: Int
    let labelled: Int
    let reliability: Float
    let trainedAt: String?
    let trainingScheduled: Bool
    let encodeMs: Double
    let trace: TraceBrief?
    let grounding: GroundingBrief?
    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case mode
        case coldStart = "cold_start"
        case partitions
        case weightedPartitions = "weighted_partitions"
        case biasTokens = "bias_tokens"
        case biasMaxAbs = "bias_max_abs"
        case gate
        case observations, labelled, reliability
        case trainedAt = "trained_at"
        case trainingScheduled = "training_scheduled"
        case encodeMs = "encode_ms"
        case trace, grounding
    }

    /// What the retrieved context did to the answer: SinatraHarness's grounding measurement.
    struct GroundingBrief: Codable {
        struct Citation: Codable {
            let partitionId: String
            let documentId: String
            let nats: Float
            let uptake: Float
            let coverage: Float
            let parrot: Float
            enum CodingKeys: String, CodingKey {
                case partitionId = "partition_id"
                case documentId = "document_id"
                case nats, uptake, coverage, parrot
            }
        }
        let measured: Bool
        let skippedReason: String?
        let grounding: Float
        let drift: Float
        let driftShare: Float
        let contextDependence: Float
        let meanContextKl: Float
        let hallucinationRisk: Float
        let parrotShare: Float
        let contentTokens: Int
        let prefillMs: Double
        let scoreMs: Double
        let attribution: [Citation]
        enum CodingKeys: String, CodingKey {
            case measured
            case skippedReason = "skipped_reason"
            case grounding, drift
            case driftShare = "drift_share"
            case contextDependence = "context_dependence"
            case meanContextKl = "mean_context_kl"
            case hallucinationRisk = "hallucination_risk"
            case parrotShare = "parrot_share"
            case contentTokens = "content_tokens"
            case prefillMs = "prefill_ms"
            case scoreMs = "score_ms"
            case attribution
        }
    }
}

/// SinatraHarness's InjectionTrace as `GET /v1/providers/local/sinatra/traces/{id}` returns it:
/// the injection layer, and the grounding layer when the turn was measured.
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
    struct Grounding: Decodable {
        struct Step: Decodable {
            let index: Int
            let token: Int
            let text: String?
            let influence: Float
            let contextKL: Float
            let tuneText: String?
            let tuneNats: Float
            let drift: Float
            let kind: String
            let risk: Float
            let pushes: [Token]?
            let rankBare: Int?
        }
        struct Summary: Decodable {
            let steps: Int
            let contentTokens: Int
            let grounding: Float
            let unsupportedShare: Float
            let contradictedShare: Float
            let drift: Float
            let driftShare: Float
            let firstDriftStep: Int?
            let contextDependence: Float
            let meanContextKL: Float
            let meanEntropyCtx: Float
            let meanEntropyBare: Float
            let hallucinationRisk: Float
            let parrotShare: Float
            let unattributed: Float
        }
        struct Attribution: Decodable {
            let partitionId: String
            let documentId: String
            let nats: Float
            let uptake: Float
            let intent: Float
            let coverage: Float
            let parrot: Float
            let relevancy: Float
        }
        let measured: Bool
        let skippedReason: String?
        let cacheReused: Bool
        let promptTokens: Int
        let bareTokens: Int
        let sharedPrefixTokens: Int
        let prefillMillis: Double
        let scoreMillis: Double
        let summary: Summary
        let attribution: [Attribution]
        let steps: [Step]
    }
    let traceId: String
    let level: String
    let mode: String
    let seed: UInt64?
    let mask: Mask?
    let steps: [Step]
    let summary: Summary
    let grounding: Grounding?
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
            let turnsMeasured: Int?
            let groundingMean: Double?
            let driftMean: Double?
            let hallucinationRiskMean: Double?
            enum CodingKeys: String, CodingKey {
                case observations, labelled, reliability, store
                case trainedAt = "trained_at"
                case lastBiasMagnitude = "last_bias_magnitude"
                case turnsMeasured = "turns_measured"
                case groundingMean = "grounding_mean"
                case driftMean = "drift_mean"
                case hallucinationRiskMean = "hallucination_risk_mean"
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

/// `GET /v1/providers/local/sinatra/analysis`: SinatraHarness's GroundingReport, read loosely.
struct GroundingReportPayload: Decodable {
    struct Correlation: Decodable {
        let x: String
        let y: String
        let pearson: Double?
        let n: Int
    }
    struct Bin: Decodable {
        let label: String
        let count: Int
        let meanGrounding: Double?
        let meanDrift: Double?
        let meanRisk: Double?
    }
    struct Citation: Decodable {
        let documentId: String
        let turns: Int
        let nats: Double
        let meanUptake: Double
    }
    struct Row: Decodable {
        let turnId: String
        let grounding: Float
        let drift: Float
        let driftShare: Float
        let hallucinationRisk: Float
        let steered: Bool
    }
    let owner: String
    let rows: [Row]
    let correlations: [Correlation]
    let bins: [Bin]
    let citations: [Citation]
    let mostDrifted: [Row]
    let unmeasured: [String: Int]?
}
