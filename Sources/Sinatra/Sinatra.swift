//
//  Sinatra.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation
import Logging

/// Sinatra is a client that houses a GBT model interface along with
/// the dataSet type required to train the model in realtime. This will be
/// used for time-series analysis, when ingesting sentiment consistently
/// throughout a conversations' aggregated context. To allow us to implement
/// a basic version of predictive empathy or intuition.
class Sinatra {
    internal let logger: SeerLogger
    /// Single source of truth for the Sinatra registry: lock-protected in-memory
    /// snapshot + serialised off-actor disk persistence via `PersistenceActor`.
    internal let cache: SeerCache<SinatraRegistry>

    static var sentimentContextLimit: Int = 4
    /// Maximum number of parked entries kept per owner. Oldest are evicted first.
    /// Prevents the DEFER path from accumulating data indefinitely across turns.
    static let maxParkedEntries: Int = 30

    init(logger: Logger) {
        self.logger = SeerLogger(logger)
        self.cache = SeerCache(
            persistence: FilePersistence(key: "sinatra/registry", kind: .basic, logger: logger)
        )
        initializeRegistry()
    }

    /// Create a fresh GBTModel with default hyperparameters.
    /// Adaptive sizing is applied at train time based on the current dataset size.
    /// Each owner gets their own model stored in the registry.
    func createModel() -> GBTModel {
        logger.debug("Create Model", "⚜️  Creating new GBTModel (GBT regression, adaptive hyperparameters)", service: .gbtTraining)
        return GBTModel()
    }
}
