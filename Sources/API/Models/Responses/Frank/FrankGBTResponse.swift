//
//  SinatraGBTResponse.swift
//  sewn-server
//



// MARK: - Top-level response

struct FrankGBTResponse: Codable {
    /// Whether the model has been trained at least once (totalTrees > 0).
    let isTrained: Bool
    /// Number of trees in the current ensemble.
    let totalTrees: Int
    /// Bias term F₀ — mean of training targets from the last training run.
    let initialPrediction: Double
    /// High-water mark of dataset sizes seen; controls which hyperparameter tier is used.
    let peakDataSetSize: Int

    // MARK: Data pipeline progress
    /// Number of labeled training points in the current DataSet.
    let dataSetSize: Int
    /// Minimum samples before GBT training fires (static floor).
    let minimumTrainingSamples: Int
    /// Number of interaction records in the collector's history.
    let interactionHistoryCount: Int
    /// Partitions parked from the last search, waiting for the next sentiment cycle.
    let parkedCount: Int

    // MARK: Feature metadata
    /// Canonical names for the 12 feature dimensions, in vector order.
    let featureNames: [String]

    // MARK: Configuration
    let hyperparameters: GBTHyperparametersView
    let indicatorPeriods: IndicatorPeriodsView
    let harmonyMemory: HarmonyMemoryView?

    // MARK: Tree structure
    let trees: [GBTTreeView]

    enum CodingKeys: String, CodingKey {
        case isTrained            = "is_trained"
        case totalTrees           = "total_trees"
        case initialPrediction    = "initial_prediction"
        case peakDataSetSize      = "peak_dataset_size"
        case dataSetSize          = "dataset_size"
        case minimumTrainingSamples = "minimum_training_samples"
        case interactionHistoryCount = "interaction_history_count"
        case parkedCount          = "parked_count"
        case featureNames         = "feature_names"
        case hyperparameters
        case indicatorPeriods     = "indicator_periods"
        case harmonyMemory        = "harmony_memory"
        case trees
    }
}

// MARK: - Hyperparameters

struct GBTHyperparametersView: Codable {
    let nEstimators: Int
    let maxDepth: Int
    let learningRate: Double
    let subsample: Double
    let colsampleByTree: Double
    let regLambda: Double
    let regAlpha: Double
    let minChildWeight: Double
    let minSplitGain: Double

    init(from h: GBTHyperparameters) {
        nEstimators     = h.nEstimators
        maxDepth        = h.maxDepth
        learningRate    = h.learningRate
        subsample       = h.subsample
        colsampleByTree = h.colsampleByTree
        regLambda       = h.regLambda
        regAlpha        = h.regAlpha
        minChildWeight  = h.minChildWeight
        minSplitGain    = h.minSplitGain
    }

    enum CodingKeys: String, CodingKey {
        case nEstimators     = "n_estimators"
        case maxDepth        = "max_depth"
        case learningRate    = "learning_rate"
        case subsample
        case colsampleByTree = "colsample_by_tree"
        case regLambda       = "reg_lambda"
        case regAlpha        = "reg_alpha"
        case minChildWeight  = "min_child_weight"
        case minSplitGain    = "min_split_gain"
    }
}

// MARK: - Indicator periods

struct IndicatorPeriodsView: Codable {
    let emaPeriod: Int
    let smaPeriod: Int
    let macdFast: Int
    let macdSlow: Int
    let macdSignalPeriod: Int
    let stochKPeriod: Int
    let stochDSignal: Int
    let momentumPeriod: Int
    let velocityPeriod: Int
    let avgVolPeriod: Int
    let vwaPeriod: Int

    init(from p: IndicatorPeriods) {
        emaPeriod        = p.emaPeriod
        smaPeriod        = p.smaPeriod
        macdFast         = p.macdFast
        macdSlow         = p.macdSlow
        macdSignalPeriod = p.macdSignalPeriod
        stochKPeriod     = p.stochKPeriod
        stochDSignal     = p.stochDSignal
        momentumPeriod   = p.momentumPeriod
        velocityPeriod   = p.velocityPeriod
        avgVolPeriod     = p.avgVolPeriod
        vwaPeriod        = p.vwaPeriod
    }

    enum CodingKeys: String, CodingKey {
        case emaPeriod        = "ema_period"
        case smaPeriod        = "sma_period"
        case macdFast         = "macd_fast"
        case macdSlow         = "macd_slow"
        case macdSignalPeriod = "macd_signal_period"
        case stochKPeriod     = "stoch_k_period"
        case stochDSignal     = "stoch_d_signal"
        case momentumPeriod   = "momentum_period"
        case velocityPeriod   = "velocity_period"
        case avgVolPeriod     = "avg_vol_period"
        case vwaPeriod        = "vwa_period"
    }
}

// MARK: - Harmony memory (IMBHS state)

struct HarmonyMemoryView: Codable {
    /// Total training cycles completed.
    let generation: Int
    /// Whether IMBHS will fire on the next training cycle.
    let shouldRun: Bool
    /// Cycles remaining before IMBHS activates (0 once warmed up).
    let warmupRemaining: Int
    /// Current pitch adjustment rate (decays from parMax → parMin over ni cycles).
    let currentPAR: Double
    /// Current bandwidth step size (decays from bwMax → bwMin over ni cycles).
    let currentBW: Int
    /// The period configuration currently in use for feature vector generation.
    let activePeriods: IndicatorPeriodsView
    /// Lowest MAE achieved across all evaluated harmonies (nil if none evaluated yet).
    let bestFitness: Double?
    /// Number of harmonies that have been fitness-evaluated so far.
    let evaluatedHarmonies: Int

    init(from hm: HarmonyMemory) {
        generation         = hm.generation
        shouldRun          = hm.shouldRun
        warmupRemaining    = max(0, HarmonyMemory.warmup - hm.generation)
        currentPAR         = hm.currentPAR
        currentBW          = hm.currentBW
        activePeriods      = IndicatorPeriodsView(from: hm.activePeriods)
        bestFitness        = hm.fitness.filter { $0.isFinite }.min()
        evaluatedHarmonies = hm.fitness.filter { $0.isFinite }.count
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case shouldRun          = "should_run"
        case warmupRemaining    = "warmup_remaining"
        case currentPAR         = "current_par"
        case currentBW          = "current_bw"
        case activePeriods      = "active_periods"
        case bestFitness        = "best_fitness"
        case evaluatedHarmonies = "evaluated_harmonies"
    }
}

// MARK: - Tree structure

/// A single node in a regression tree.
///
/// Leaf nodes have `isLeaf == true`; `threshold`, `leftChild`, and `rightChild`
/// are meaningless for leaves (set to 0 / -1). Split nodes have `leafValue == 0`.
struct GBTNodeView: Codable {
    /// Position in the flat node array for this tree.
    let index: Int
    let isLeaf: Bool
    /// Feature dimension this node splits on (-1 for leaves).
    let featureIndex: Int
    /// Human-readable name of the split feature, or `"leaf"` for leaf nodes.
    let featureName: String
    /// Split threshold: samples with `x[featureIndex] ≤ threshold` go left.
    let threshold: Double
    /// Index of the left child in the flat array (-1 for leaves).
    let leftChild: Int
    /// Index of the right child in the flat array (-1 for leaves).
    let rightChild: Int
    /// Predicted residual contribution — only meaningful for leaf nodes.
    let leafValue: Double

    init(index: Int, node: GBTNode, featureNames: [String]) {
        self.index       = index
        self.isLeaf      = node.featureIndex == -1
        self.featureIndex = node.featureIndex
        self.featureName = node.featureIndex >= 0 && node.featureIndex < featureNames.count
                           ? featureNames[node.featureIndex]
                           : (node.featureIndex == -1 ? "leaf" : "unknown[\(node.featureIndex)]")
        self.threshold   = node.threshold
        self.leftChild   = node.leftChild
        self.rightChild  = node.rightChild
        self.leafValue   = node.leafValue
    }

    enum CodingKeys: String, CodingKey {
        case index
        case isLeaf      = "is_leaf"
        case featureIndex = "feature_index"
        case featureName = "feature_name"
        case threshold
        case leftChild   = "left_child"
        case rightChild  = "right_child"
        case leafValue   = "leaf_value"
    }
}

struct GBTTreeView: Codable {
    /// Zero-based position of this tree in the ensemble.
    let index: Int
    let nodeCount: Int
    let nodes: [GBTNodeView]

    init(index: Int, tree: GBTTree, featureNames: [String]) {
        self.index     = index
        self.nodeCount = tree.nodes.count
        self.nodes     = tree.nodes.enumerated().map {
            GBTNodeView(index: $0.offset, node: $0.element, featureNames: featureNames)
        }
    }

    enum CodingKeys: String, CodingKey {
        case index
        case nodeCount = "node_count"
        case nodes
    }
}
