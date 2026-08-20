import Foundation
//
//  FrankParkingResponse.swift
//  seer-server
//



// MARK: - Top-level response

/// Debug snapshot of the parking pipeline for a single owner.
/// Returned by `POST /v1/frank/parking`.
struct FrankParkingResponse: Codable {
    /// Partitions currently parked and awaiting the next sentiment cycle.
    let pendingParked: [PendingParkedView]
    /// The last 20 interaction records that completed the pipeline
    /// (sentiment → feature vector → GBT label), newest last.
    let recentInteractions: [InteractionEventView]
    /// Full breakdown of the most recent sentiment analysis result.
    let lastSentiment: SentimentView?
    /// Per-partition GBT adjustment entries from the most recent search.
    /// Shows which partitions were boosted, unchanged, demoted, or dropped.
    let lastSearchAdjustments: [AdjustmentEntryView]

    // MARK: Pipeline status
    let interactionHistoryCount: Int
    let dataSetSize: Int
    let minimumTrainingSamples: Int
    /// Minimum interaction history size before feature vectors can be generated.
    let featureVectorReadyAt: Int
    let isTrained: Bool
    let totalTrees: Int

    // MARK: Active IMBHS configuration
    let indicatorPeriods: IndicatorPeriodsView
    let harmonyMemory: HarmonyMemoryView?
    /// Trajectory snapshot from the most recent prepare() cycle.
    let trajectory: SinatraTrajectorySnapshot?

    enum CodingKeys: String, CodingKey {
        case pendingParked            = "pending_parked"
        case recentInteractions       = "recent_interactions"
        case lastSentiment            = "last_sentiment"
        case lastSearchAdjustments    = "last_search_adjustments"
        case interactionHistoryCount  = "interaction_history_count"
        case dataSetSize              = "dataset_size"
        case minimumTrainingSamples   = "minimum_training_samples"
        case featureVectorReadyAt     = "feature_vector_ready_at"
        case isTrained                = "is_trained"
        case totalTrees               = "total_trees"
        case indicatorPeriods         = "indicator_periods"
        case harmonyMemory            = "harmony_memory"
        case trajectory
    }
}

// MARK: - Adjustment entry view

struct AdjustmentEntryView: Codable {
    let partitionId: String
    let originalDistance: Float
    let adjustedDistance: Float
    /// nil when the adaptive threshold has not yet been calibrated (effectiveThreshold == .infinity).
    let threshold: Float?
    /// "boosted" | "unchanged" | "demoted" | "dropped"
    let status: String
    /// adjustedDistance / originalDistance. < 1.0 = boosted, > 1.0 = demoted.
    let factor: Float

    init(from entry: SinatraAdjustment.Entry) {
        partitionId      = entry.partitionId
        originalDistance = entry.originalDistance
        adjustedDistance = entry.adjustedDistance
        threshold        = entry.threshold.isInfinite ? nil : entry.threshold
        factor           = entry.factor
        status           = entry.status.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case partitionId      = "partition_id"
        case originalDistance = "original_distance"
        case adjustedDistance = "adjusted_distance"
        case threshold
        case status
        case factor
    }
}

// MARK: - Pending parked item

/// A partition parked from the last search, awaiting sentiment analysis.
struct PendingParkedView: Codable {
    let id: String
    /// The document this partition belongs to.
    let documentId: String
    let distance: Float
    /// GBT-predicted sentiment weight for this partition using the current model and feature
    /// vector. Nil when the model is untrained or history < 20 interactions. Range: [0, 1].
    let predictedScore: Double?

    init(from parked: SinatraTrainingData.Parked, predictedScore: Double? = nil) {
        id                  = parked.id
        documentId          = parked.documentId
        distance            = parked.distance
        self.predictedScore = predictedScore
    }

    enum CodingKeys: String, CodingKey {
        case id
        case documentId   = "document_id"
        case distance
        case predictedScore = "predicted_score"
    }
}

// MARK: - Interaction event

/// One completed pipeline event: a parked partition that was matched with a
/// sentiment weight and (when history is deep enough) a feature vector.
struct InteractionEventView: Codable {
    let timestamp: Date
    let partitionId: String
    /// The document this partition belongs to.
    let documentId: String
    let sentimentWeight: Double
    let responseLength: Int
    /// Current 14-D feature vector for this partition, or nil if interaction
    /// history has not yet reached the 20-record minimum.
    let featureVector: NamedFeatureVectorView?

    init(record: InteractionRecord, featureVector: NamedFeatureVectorView?) {
        timestamp       = record.timestamp
        partitionId     = record.id
        documentId      = record.documentId
        sentimentWeight = record.sentimentWeight
        responseLength  = record.responseLength
        self.featureVector = featureVector
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case partitionId     = "partition_id"
        case documentId      = "document_id"
        case sentimentWeight = "sentiment_weight"
        case responseLength  = "response_length"
        case featureVector   = "feature_vector"
    }
}

// MARK: - Named feature vector

struct NamedFeatureVectorView: Codable {
    /// Feature name + value pairs in vector order.
    let pairs: [FeaturePairView]

    init(values: [Double], names: [String]) {
        pairs = zip(names, values).map { FeaturePairView(name: $0.0, value: $0.1) }
    }
}

struct FeaturePairView: Codable {
    let name: String
    let value: Double
}

// MARK: - Sentiment view

/// Human-readable breakdown of a `Sinatra.Sentiment` result.
struct SentimentView: Codable {
    let sentiment: String
    let emotionalTones: [String]
    let reactionTypes: [String]
    let keyPhrases: [String]
    let confidence: Double
    let notes: String
    /// Normalised weight in [0, 1] used as the GBT training label.
    let weight: Double

    init(from s: Sinatra.Sentiment) {
        sentiment     = Self.kindString(s.sentiment)
        emotionalTones = s.emotionalTones.map { $0.displayName }
        reactionTypes  = s.reactionTypes.map { $0.displayName }
        keyPhrases     = s.keyPhrases
        confidence     = s.confidence
        notes          = s.notes
        weight         = s.calculateWeight()
    }

    private static func kindString(_ kind: Sinatra.Sentiment.Kind) -> String {
        switch kind {
        case .positive:        return "Positive"
        case .negative:        return "Negative"
        case .neutral:         return "Neutral"
        case .mixed:           return "Mixed"
        case .ambiguous:       return "Ambiguous"
        case .unknown(let v):  return v.capitalized
        }
    }

    enum CodingKeys: String, CodingKey {
        case sentiment
        case emotionalTones = "emotional_tones"
        case reactionTypes  = "reaction_types"
        case keyPhrases     = "key_phrases"
        case confidence
        case notes
        case weight
    }
}
