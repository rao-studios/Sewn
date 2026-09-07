//
//  GBTTrainer.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/20/26.
//

import Foundation

/// Pure-Swift gradient boosted tree trainer for squared-error regression.
///
/// ## Algorithm
/// Fits an additive ensemble F(x) = F₀ + Σ η·treeₜ(x) where:
/// - **F₀** = mean of training targets (bias term)
/// - **η** = learning rate (shrinkage per tree)
/// - Each tree fits the negative gradient (residuals) of the squared-error loss
///
/// ### Loss and gradients (squared-error)
/// - L(y, ŷ) = ½(ŷ − y)²
/// - Gradient:  gᵢ = ŷᵢ − yᵢ  (how much the current prediction overshoots)
/// - Hessian:   hᵢ = 1.0       (constant for squared-error)
///
/// ### Leaf score (L1 + L2 regularization)
/// ```
/// score = sign(−ΣG) · max(0, |ΣG| − α) / (ΣH + λ)
/// ```
/// where G = sum of gradients, H = sum of hessians, λ = regLambda, α = regAlpha.
///
/// ### Split gain
/// ```
/// gain = 0.5 · [ GL²/(HL+λ) + GR²/(HR+λ) − G²/(H+λ) ] − γ
/// ```
/// Splits are only accepted when `gain > minSplitGain` (γ).
enum GBTTrainer {
    /// Train from scratch on `data` using `params` and return the fitted ensemble.
    ///
    /// Pure function: takes inputs, returns `(trees, initialPrediction)`.
    /// `GBTModel.train(data:)` resolves hyperparameters and applies the result.
    static func train(
        data: DataSet,
        params: GBTHyperparameters
    ) -> (trees: [GBTTree], initialPrediction: Double) {
        guard let outputs = data.outputs, !outputs.isEmpty, data.size > 0 else {
            return ([], 0.5)
        }

        let targets = outputs.map { $0[0] }
        let inputs  = data.inputs
        let n       = targets.count
        let d       = data.inputDimension

        let initialPrediction = targets.reduce(0, +) / Double(n)
        var trees: [GBTTree] = []

        // Running ensemble predictions for all training points
        var F = [Double](repeating: initialPrediction, count: n)

        for _ in 0..<params.nEstimators {
            // Row and column subsampling for regularization and diversity
            let rowSample = subsampleIndices(count: n, rate: params.subsample)
            let colSample = subsampleIndices(count: d, rate: params.colsampleByTree)

            // Gradients (residuals) and hessians for the sampled rows only
            let gradients = rowSample.map { F[$0] - targets[$0] }
            let hessians  = [Double](repeating: 1.0, count: rowSample.count)

            let sampledInputs = rowSample.map { inputs[$0] }

            let builder = TreeBuilder(
                inputs:    sampledInputs,
                gradients: gradients,
                hessians:  hessians,
                features:  colSample,
                params:    params
            )
            let tree = builder.build()
            trees.append(tree)

            // Update predictions for ALL n points (not just the sampled rows)
            for i in 0..<n {
                F[i] += params.learningRate * tree.predict(inputs[i])
            }
        }

        return (trees, initialPrediction)
    }

    // MARK: - Subsampling

    /// Returns a random sample of `floor(count × rate)` (minimum 1) indices from `[0, count)`.
    /// Uses a partial Fisher-Yates shuffle — O(count) time, no sorting needed.
    /// Returns the full range when `rate >= 1.0` or `count <= 1`.
    private static func subsampleIndices(count: Int, rate: Double) -> [Int] {
        guard rate < 1.0, count > 1 else { return Array(0..<count) }
        let sampleSize = max(1, Int(Double(count) * rate))
        var all = Array(0..<count)
        // Shuffle random elements into the last `sampleSize` positions
        for i in stride(from: count - 1, through: count - sampleSize, by: -1) {
            let j = Int.random(in: 0...i)
            all.swapAt(i, j)
        }
        return Array(all.suffix(sampleSize))
    }
}

// MARK: - Tree Builder

/// Stateful builder that constructs one regression tree via greedy recursive splitting.
///
/// Implemented as a class so the `nodes` array can be mutated freely across
/// recursive `buildNode` calls without `inout` parameter threading.
///
/// The root node is always at `nodes[0]`. Children are appended after the parent's
/// placeholder slot is reserved, so the flat index scheme is self-consistent.
private final class TreeBuilder {
    var nodes: [GBTNode] = []

    private let inputs:    [[Double]]
    private let gradients: [Double]
    private let hessians:  [Double]
    private let features:  [Int]
    private let params:    GBTHyperparameters

    init(inputs:    [[Double]],
         gradients: [Double],
         hessians:  [Double],
         features:  [Int],
         params:    GBTHyperparameters) {
        self.inputs    = inputs
        self.gradients = gradients
        self.hessians  = hessians
        self.features  = features
        self.params    = params
    }

    func build() -> GBTTree {
        _ = buildNode(indices: Array(0..<inputs.count), depth: 0)
        return GBTTree(nodes: nodes)
    }

    // MARK: - Recursive node construction

    /// Builds a (sub)tree rooted at the returned index into `nodes`.
    ///
    /// Leaf conditions:
    /// - Reached maximum depth
    /// - Total hessian mass below `2 × minChildWeight` (can't form two valid children)
    /// - Only one sample remains
    @discardableResult
    private func buildNode(indices: [Int], depth: Int) -> Int {
        let G = indices.reduce(0.0) { $0 + gradients[$1] }
        let H = indices.reduce(0.0) { $0 + hessians[$1] }

        let isLeaf = depth >= params.maxDepth
                  || H < 2 * params.minChildWeight
                  || indices.count <= 1

        if isLeaf {
            let lv = leafScore(G: G, H: H)
            nodes.append(GBTNode(featureIndex: -1, threshold: 0, leftChild: -1, rightChild: -1, leafValue: lv))
            return nodes.count - 1
        }

        // Find the best split across candidate features.
        // bestGain = 0.0: the gain formula subtracts minSplitGain (γ), so `gain > 0`
        // accepts a split when rawGain > γ — correct for γ ≥ 0. If γ < 0 is ever
        // allowed, initialise bestGain to -γ instead to restore the correct threshold.
        var bestGain        = 0.0
        var bestFeature     = -1
        var bestThreshold   = 0.0
        var bestSplitK      = -1
        var bestSortedOrder: [Int]?

        for f in features {
            // Sort sample indices by feature f value
            let sorted = indices.sorted { inputs[$0][f] < inputs[$1][f] }
            var GL = 0.0, HL = 0.0

            for k in 0..<(sorted.count - 1) {
                GL += gradients[sorted[k]]
                HL += hessians[sorted[k]]
                let GR = G - GL
                let HR = H - HL

                // Skip: child too small for a stable split
                if HL < params.minChildWeight || HR < params.minChildWeight { continue }
                // Skip: identical feature values — no threshold exists between them
                if inputs[sorted[k]][f] == inputs[sorted[k + 1]][f] { continue }

                let gain = 0.5 * (
                    GL * GL / (HL + params.regLambda) +
                    GR * GR / (HR + params.regLambda) -
                     G *  G / ( H + params.regLambda)
                ) - params.minSplitGain

                if gain > bestGain {
                    bestGain        = gain
                    bestFeature     = f
                    bestThreshold   = (inputs[sorted[k]][f] + inputs[sorted[k + 1]][f]) / 2
                    bestSplitK      = k
                    bestSortedOrder = sorted  // one copy per feature improvement, not per threshold
                }
            }
        }

        // No beneficial split found — fall back to leaf.
        // Partition once here using the saved split index, avoiding repeated
        // Array allocations inside the inner loop (was O(features × improvements)).
        guard bestFeature != -1, let order = bestSortedOrder else {
            let lv = leafScore(G: G, H: H)
            nodes.append(GBTNode(featureIndex: -1, threshold: 0, leftChild: -1, rightChild: -1, leafValue: lv))
            return nodes.count - 1
        }

        let bestLeftIdx  = Array(order[0...bestSplitK])
        let bestRightIdx = Array(order[(bestSplitK + 1)...])

        // Reserve a placeholder slot for this internal node.
        // Children are built next; their indices are not yet known.
        let nodeIdx = nodes.count
        nodes.append(GBTNode(featureIndex: 0, threshold: 0, leftChild: 0, rightChild: 0, leafValue: 0))

        let leftIdx  = buildNode(indices: bestLeftIdx,  depth: depth + 1)
        let rightIdx = buildNode(indices: bestRightIdx, depth: depth + 1)

        // Back-fill the internal node now that child indices are known
        nodes[nodeIdx] = GBTNode(
            featureIndex: bestFeature,
            threshold:    bestThreshold,
            leftChild:    leftIdx,
            rightChild:   rightIdx,
            leafValue:    0
        )
        return nodeIdx
    }

    // MARK: - Leaf score

    /// Regularized leaf score with L1 soft-thresholding and L2 penalty.
    ///
    /// Plain (no L1): `−ΣG / (ΣH + λ)`
    /// With L1:       `sign(−ΣG) · max(0, |ΣG| − α) / (ΣH + λ)`
    ///
    /// When `|G| ≤ α` the numerator is zero, producing a zero leaf value —
    /// this is the sparsity-inducing effect of L1 regularization.
    private func leafScore(G: Double, H: Double) -> Double {
        let absG      = abs(G)
        let threshold = absG - params.regAlpha
        // G == 0.0 guard: when G is exactly zero the ternary (G > 0 ? -1 : +1) returns
        // +1 and produces a spurious positive leaf. In practice, exact zero is nearly
        // impossible with floating-point gradients, and regAlpha > 0 already catches it
        // via `threshold > 0`; this guard is belt-and-suspenders for correctness.
        guard threshold > 0, G != 0.0 else { return 0.0 }
        // sign(-G): negative when G > 0 (overshoot → push down), positive when G < 0
        return (G > 0 ? -1.0 : 1.0) * threshold / (H + params.regLambda)
    }
}
