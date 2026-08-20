//
//  GBTHyperparameters.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/20/26.
//

import Foundation

/// Configuration for the Gradient Boosted Trees trainer.
///
/// All fields are Codable so the model (including its hyperparameters) survives
/// registry persistence round-trips. New fields should use `decodeIfPresent`
/// in any manual decoder to maintain forward compatibility.
struct GBTHyperparameters: Codable {
    var nEstimators: Int        = 50    // T: number of boosting rounds
    var maxDepth: Int           = 4     // maximum depth per regression tree
    var learningRate: Double    = 0.1   // η: per-tree shrinkage factor
    var subsample: Double       = 0.8   // row subsampling rate per tree (implicit regularization)
    var colsampleByTree: Double = 0.8   // column subsampling rate per tree
    var regLambda: Double       = 1.0   // L2 leaf regularization (prevents large leaf scores)
    var regAlpha: Double        = 0.1   // L1 leaf regularization (mild sparsity pressure)
    var minChildWeight: Double  = 3.0   // min sum of hessians required for a valid child node
    var minSplitGain: Double    = 0.0   // γ: minimum information gain required to create a split

    /// Returns hyperparameters scaled conservatively to the training dataset size.
    ///
    /// Small datasets (n < 30) use fewer trees and stronger regularization to stay stable
    /// when data is too sparse for reliable split candidates. Defaults apply at n ≥ 80.
    ///
    /// The tier boundaries (n = 30, n = 80) are step-function thresholds. To avoid
    /// tier regression when a temporary DataSet rebuild produces fewer rows, callers
    /// should pass the **peak** dataset size ever seen rather than the current size.
    /// `GBTModel.train(data:)` handles this automatically via `peakDataSetSize`.
    static func adaptive(datasetSize n: Int) -> GBTHyperparameters {
        var p = GBTHyperparameters()
        if n < 30 {
            p.nEstimators    = 20
            p.maxDepth       = 3
            p.minChildWeight = 5.0
            p.regLambda      = 5.0
        } else if n < 80 {
            p.nEstimators    = 35
            p.maxDepth       = 3
            p.minChildWeight = 4.0
            p.regLambda      = 2.0
        }
        // n >= 80: use defaults (50 trees, depth 4, minChildWeight 3, lambda 1)
        return p
    }
}
