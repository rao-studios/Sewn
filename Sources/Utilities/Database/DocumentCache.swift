//
//  DocumentCache.swift
//  seer-server
//
//  Created by Ritesh Pakala on 3/19/26.
//

import Foundation

/// Thread-safe in-memory cache for `Seer.Document` objects.
///
/// Analogous to `RegistryMutator` and `TableMutator` but without the actor
/// serialization overhead — document reads are the most frequent operation and
/// must never queue behind writes. An `OSAllocatedUnfairLock` gives sub-microsecond
/// acquire/release with full thread safety.
///
/// All mutations go through the typed API (`cache`, `evict`, `seed`).
/// Never access `_store` directly from outside this file.
final class DocumentCache: Sendable {
    private let _store: ReadWriteValue<[DocumentID: Seer.Document]>

    init() {
        self._store = ReadWriteValue([:])
    }

    // MARK: - Read

    func get(_ id: DocumentID) -> Seer.Document? {
        _store.withReadLock { $0[id] }
    }

    // MARK: - Write

    func cache(_ document: Seer.Document) {
        _store.withWriteLock { $0[document.id] = document }
    }

    func evict(_ id: DocumentID) {
        _store.withWriteLock { $0.removeValue(forKey: id) }
    }

    /// Bulk-seeds the cache in a single lock acquisition. Used at startup only.
    func seed(_ initial: [DocumentID: Seer.Document]) {
        _store.withWriteLock { $0 = initial }
    }

    /// Inserts multiple documents in a single lock acquisition.
    func cacheBatch(_ documents: [Seer.Document]) {
        _store.withWriteLock { store in
            for document in documents { store[document.id] = document }
        }
    }
}
