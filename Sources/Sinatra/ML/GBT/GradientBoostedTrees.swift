//
//  GradientBoostedTrees.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/20/26.
//

import Foundation

/// A single node in a regression tree, stored in a flat array for cache-friendly traversal.
///
/// - When `featureIndex == -1`, this is a leaf node and `leafValue` holds the predicted residual.
/// - When `featureIndex >= 0`, this is a split node: samples with `x[featureIndex] <= threshold`
///   go left (to `nodes[leftChild]`), all others go right (to `nodes[rightChild]`).
struct GBTNode: Codable {
    var featureIndex: Int   // -1 for leaf; feature dimension index for split nodes
    var threshold: Double   // split value (ignored for leaves)
    var leftChild: Int      // index into GBTTree.nodes; -1 for leaves
    var rightChild: Int     // index into GBTTree.nodes; -1 for leaves
    var leafValue: Double   // predicted residual (valid only when featureIndex == -1)
}

/// A single regression tree stored as a flat node array.
///
/// The root is always at index 0. Prediction walks the array until a leaf is reached.
/// Flat storage avoids pointer chasing and makes Codable serialization trivial.
struct GBTTree: Codable {
    var nodes: [GBTNode]

    func predict(_ x: [Double]) -> Double {
        guard !nodes.isEmpty else { return 0.0 }
        var idx = 0
        while nodes[idx].featureIndex >= 0 {
            let node = nodes[idx]
            idx = x[node.featureIndex] <= node.threshold
                ? node.leftChild
                : node.rightChild
        }
        return nodes[idx].leafValue
    }
}

/// Gradient Boosted Trees regression model.
///
/// Drop-in replacement for `SVMModel` from the perspective of `Sinatra+Inference.swift`
/// and `Sinatra+Sentiment.swift`. Preserves the `predictOne(inputs:)` and `train(data:)`
/// interfaces so no call-site logic changes are needed.
///
/// The model is retrained from scratch on every `prepare()` cycle. At the target dataset
/// size (≤ 200 points, 12 features, 50 trees), a full retrain takes well under 1ms —
/// no incremental update machinery is needed or desired.
struct GBTModel: Codable {
    var trees: [GBTTree]
    var initialPrediction: Double   // mean of training targets (bias term / F₀)
    var hyperparameters: GBTHyperparameters
    /// Monotonic high-water mark of dataset sizes seen across all `train()` calls.
    /// Passed to `adaptive()` so the model never regresses to a weaker hyperparameter
    /// tier when a temporary DataSet rebuild (e.g. after an IMBHS period change)
    /// produces fewer rows than the historical peak.
    private(set) var peakDataSetSize: Int

    /// Number of trees in the ensemble after the last training call.
    var totalTrees: Int { trees.count }

    init(hyperparameters: GBTHyperparameters = GBTHyperparameters()) {
        self.trees             = []
        self.initialPrediction = 0.5
        self.hyperparameters   = hyperparameters
        self.peakDataSetSize   = 0
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case trees, initialPrediction, hyperparameters, peakDataSetSize
    }

    init(from decoder: Decoder) throws {
        let c             = try decoder.container(keyedBy: CodingKeys.self)
        trees             = try c.decode([GBTTree].self,           forKey: .trees)
        initialPrediction = try c.decode(Double.self,              forKey: .initialPrediction)
        hyperparameters   = try c.decode(GBTHyperparameters.self,  forKey: .hyperparameters)
        // decodeIfPresent: field absent in older JSON → default 0; adaptive() recomputes tier
        // from the current dataset size on the next train() call.
        peakDataSetSize   = try c.decodeIfPresent(Int.self,        forKey: .peakDataSetSize) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trees,             forKey: .trees)
        try c.encode(initialPrediction, forKey: .initialPrediction)
        try c.encode(hyperparameters,   forKey: .hyperparameters)
        try c.encode(peakDataSetSize,   forKey: .peakDataSetSize)
    }

    // MARK: - Inference

    /// Predict a sentiment weight for the given feature vector.
    ///
    /// Returns the raw ensemble sum (bias + Σ η·tree(x)). The caller in
    /// `Sinatra+Inference.swift` applies the adjustment factor `1.5 - predicted`
    /// and clamps the result to [0.5, 1.5] — identical to the former SVMModel path.
    func predictOne(inputs: [Double]) -> Double {
        trees.reduce(initialPrediction) { acc, tree in
            acc + hyperparameters.learningRate * tree.predict(inputs)
        }
    }

    // MARK: - Training

    /// Retrain the model from scratch on `data`.
    ///
    /// Adaptive hyperparameters are selected based on `peakDataSetSize` — the largest
    /// dataset size seen across all prior `train()` calls — rather than the current
    /// `data.size`. This provides hysteresis against temporary dataset shrinkage
    /// (e.g. after an IMBHS period change that rebuilds the DataSet from history):
    /// once the model has crossed a regularization tier boundary, it stays there.
    /// `GBTTrainer` overwrites `trees` and `initialPrediction` in place.
    mutating func train(data: DataSet) {
        peakDataSetSize = max(peakDataSetSize, data.size)
        hyperparameters = .adaptive(datasetSize: peakDataSetSize)
        let result = GBTTrainer.train(data: data, params: hyperparameters)
        trees             = result.trees
        initialPrediction = result.initialPrediction
    }
}
