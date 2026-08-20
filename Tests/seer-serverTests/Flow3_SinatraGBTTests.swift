//
//  Flow3_SinatraGBTTests.swift
//  seer-serverTests
//
//  Deterministic test for the Sinatra GBT model (the "SVM" of Sinatra).
//
//  Non-determinism in training comes solely from `GBTTrainer.subsampleIndices`,
//  which calls `Int.random(in:)` for row and column subsampling. Setting
//  `subsample = 1.0` and `colsampleByTree = 1.0` forces both functions to return
//  the full index range — no randomness, fully reproducible trees.
//
//  We call `GBTTrainer.train(model:data:)` directly to bypass `GBTModel.train(data:)`,
//  which would overwrite hyperparameters via `GBTHyperparameters.adaptive()`.
//
//  Dataset:
//    Feature = [0.0] → target 0.9  (positive sentiment — liked this partition)
//    Feature = [1.0] → target 0.1  (negative sentiment — disliked this partition)
//    12 examples of each class → 24 total, 1 feature dimension
//
//  After training the GBT must:
//    1. Predict > 0.5 for x = [0.0]  →  adjustment factor < 1.0  →  distance shrinks
//    2. Predict < 0.5 for x = [1.0]  →  adjustment factor > 1.0  →  distance grows
//    3. Produce identical predictions on every run (determinism guarantee)
//

import XCTest
@testable import seer_server

final class Flow3_SinatraGBTTests: XCTestCase {

    // MARK: - Helpers

    /// Build the binary sentiment dataset.
    ///
    /// 12 × [0.0] → 0.9  (positive)
    /// 12 × [1.0] → 0.1  (negative)
    private func makeSentimentDataset() -> DataSet {
        var data = DataSet(dataType: .Regression, inputDimension: 1, outputDimension: 1)
        for _ in 0..<12 { try! data.addDataPoint(input: [0.0], output: [0.9]) }
        for _ in 0..<12 { try! data.addDataPoint(input: [1.0], output: [0.1]) }
        return data
    }

    /// Build a trained GBTModel with subsampling disabled for full determinism.
    ///
    /// Subsampling is disabled by setting both rates to 1.0 — `subsampleIndices`
    /// then returns the full index range without touching the RNG.
    /// `GBTTrainer.train` is called directly so `adaptive()` cannot override params.
    private func makeTrainedModel(nEstimators: Int = 20) -> GBTModel {
        var hyperparameters = GBTHyperparameters()
        hyperparameters.nEstimators     = nEstimators
        hyperparameters.maxDepth        = 3
        hyperparameters.learningRate    = 0.1
        hyperparameters.subsample       = 1.0   // ← disables row RNG
        hyperparameters.colsampleByTree = 1.0   // ← disables column RNG
        hyperparameters.minChildWeight  = 1.0
        hyperparameters.regLambda       = 1.0
        hyperparameters.regAlpha        = 0.0
        hyperparameters.minSplitGain    = 0.0
        let result = GBTTrainer.train(data: makeSentimentDataset(), params: hyperparameters)
        var model = GBTModel(hyperparameters: hyperparameters)
        model.trees             = result.trees
        model.initialPrediction = result.initialPrediction
        return model
    }

    // MARK: - Single deterministic test

    func testGBTLearnsSentimentAndAdjustsDistancesCorrectly() {
        let model = makeTrainedModel()

        // ── 1. Model is trained ──────────────────────────────────────────────────
        XCTAssertEqual(model.totalTrees, 20,
            "GBT must build exactly nEstimators trees")
        XCTAssertFalse(model.trees.isEmpty)

        // ── 2. Prediction direction ──────────────────────────────────────────────
        // The dataset maps x=0 → 0.9 and x=1 → 0.1 so after learning:
        //   predPositive must be > 0.5  (leaning toward 0.9)
        //   predNegative must be < 0.5  (leaning toward 0.1)
        let predPositive = model.predictOne(inputs: [0.0])
        let predNegative = model.predictOne(inputs: [1.0])

        XCTAssertGreaterThan(predPositive, 0.5,
            "Model must predict positive sentiment (>0.5) for positively-labeled inputs")
        XCTAssertLessThan(predNegative, 0.5,
            "Model must predict negative sentiment (<0.5) for negatively-labeled inputs")
        XCTAssertGreaterThan(predPositive, predNegative,
            "Positive-example prediction must exceed negative-example prediction")

        // ── 3. Sinatra adjustment factor (from Sinatra+Inference.swift) ──────────
        // adjustmentFactor = 1.5 − predicted,  clamped to [0.5, 1.5]
        // Positive sentiment → factor < 1.0 → adjustedDistance < original  (boosted)
        // Negative sentiment → factor > 1.0 → adjustedDistance > original  (penalized)
        let factorPositive = max(0.5, min(1.5, 1.5 - predPositive))
        let factorNegative = max(0.5, min(1.5, 1.5 - predNegative))

        XCTAssertLessThan(factorPositive, 1.0,
            "Positive-sentiment partition must receive a distance-reducing factor (<1.0)")
        XCTAssertGreaterThan(factorNegative, 1.0,
            "Negative-sentiment partition must receive a distance-inflating factor (>1.0)")

        let originalDistance: Float = 0.5
        let adjustedPositive = originalDistance * Float(factorPositive)
        let adjustedNegative = originalDistance * Float(factorNegative)

        XCTAssertLessThan(adjustedPositive, originalDistance,
            "Liked partition distance must decrease after Sinatra adjustment")
        XCTAssertGreaterThan(adjustedNegative, originalDistance,
            "Disliked partition distance must increase after Sinatra adjustment")

        // ── 4. Determinism ───────────────────────────────────────────────────────
        // Training an identical model on the identical dataset must produce
        // bit-for-bit identical predictions — no RNG involvement.
        let model2 = makeTrainedModel()
        XCTAssertEqual(model.predictOne(inputs: [0.0]), model2.predictOne(inputs: [0.0]),
            "GBT prediction must be identical across training runs with subsampling disabled")
        XCTAssertEqual(model.predictOne(inputs: [1.0]), model2.predictOne(inputs: [1.0]),
            "GBT prediction must be identical across training runs with subsampling disabled")
    }
}
