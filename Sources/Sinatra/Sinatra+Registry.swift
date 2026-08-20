//
//  Sinatra+Registry.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 1/29/26.
//

import Foundation

extension Sinatra {
    /// Seeds the cache from disk synchronously. Called once at init.
    func initializeRegistry() {
        let existing = cache.seedFromDisk(makeDefault: SinatraRegistry.init)
        // If no file existed yet, nothing extra to do — seedFromDisk already seeded the default.
        if existing.parked.isEmpty && existing.models.isEmpty && existing.collectors.isEmpty {
            // First launch or empty registry — nothing to log.
        } else {
            logger.debug(
                "Registry Restored",
                "⚜️ Restored existing registry: \(existing.parked.count) owners with parked data, \(existing.models.count) trained models, \(existing.collectors.count) collectors, \(existing.dataSets.count) dataSets",
                service: .sinatra
            )
        }
    }
}

extension Sinatra {
    /// Synchronous, lock-protected read of the latest registry state.
    var registry: SinatraRegistry? { cache.snapshot }

    /// Writes `registry` to the in-memory cache and schedules an async disk save.
    func saveRegistry(_ registry: SinatraRegistry?) {
        guard let registry else { return }
        cache.update(registry)
        cache.saveAsync(registry)
    }

    /// Atomically read-modify-write the registry under the cache lock,
    /// then schedule an async disk save outside the lock.
    func updateRegistry(_ mutate: (inout SinatraRegistry) -> Void) {
        let updated = cache.modify(makeDefault: SinatraRegistry.init, mutate)
        cache.saveAsync(updated)
    }

    /// Overwrites all Sinatra data for a given owner with the contents of a `SinatraExport`.
    /// Existing data for that owner is replaced atomically.
    func importOwner(id: String, from export: SinatraExport) {
        let owner = SeerRegistry.Owner(id: id)
        updateRegistry { reg in
            reg.parked[owner]            = export.parked.isEmpty ? nil : export.parked
            reg.collectors[owner]        = export.collector
            reg.dataSets[owner]          = export.dataSet
            reg.models[owner]            = export.model
            reg.harmonyMemories[owner]   = export.harmonyMemory
            reg.lastSentiments[owner]    = export.lastSentiment
            reg.lastSearchEntries[owner] = export.lastSearchEntries.isEmpty ? nil : export.lastSearchEntries
            reg.lastTrajectories[owner]  = export.lastTrajectory
        }
    }

    /// Removes all Sinatra data for a given owner: parked data, collector,
    /// dataset, trained model, harmony memory, last sentiment, and last search entries.
    /// - Returns: `true` if the owner had any data in the registry.
    @discardableResult
    func removeOwner(id: String) -> Bool {
        let owner = SeerRegistry.Owner(id: id)
        var hadData = false
        updateRegistry { reg in
            hadData = reg.parked[owner] != nil
                || reg.collectors[owner] != nil
                || reg.dataSets[owner] != nil
                || reg.models[owner] != nil
                || reg.harmonyMemories[owner] != nil
                || reg.lastSentiments[owner] != nil
                || reg.lastSearchEntries[owner] != nil
                || reg.lastTrajectories[owner] != nil
            reg.parked.removeValue(forKey: owner)
            reg.collectors.removeValue(forKey: owner)
            reg.dataSets.removeValue(forKey: owner)
            reg.models.removeValue(forKey: owner)
            reg.harmonyMemories.removeValue(forKey: owner)
            reg.lastSentiments.removeValue(forKey: owner)
            reg.lastSearchEntries.removeValue(forKey: owner)
            reg.lastTrajectories.removeValue(forKey: owner)
        }
        return hadData
    }
}
