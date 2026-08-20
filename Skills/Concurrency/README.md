# Concurrency — Mutators, IndexQueue, and PersistenceActor

The entire write path in Seer is serialized through a small set of actors. Understanding these is essential before touching any mutation code, because the races they prevent are not obvious and took production incidents to discover.

Source files:
- `Sources/Database/Mutators/TableMutator.swift`
- `Sources/Database/Mutators/RegistryMutator.swift`
- `Sources/Database/Mutators/PersonalHNSWMutator.swift`
- `Sources/Utilities/Database/IndexQueue.swift`
- `Sources/Utilities/Persistence/PersistenceActor.swift`

---

## The Core Problem: Last-Write-Wins

Without actor serialization, concurrent embedding requests create this race:

```
Request A:  load registry → mutate → save registry [A's version]
Request B:            load registry → mutate → save registry [B's version, overwrites A]
```

Request A's document registration is silently dropped. No error, no panic, no log. The document appears to the user as indexed but is invisible to all subsequent searches.

The same race applies to `PartitionTable` (for HNSW nodes) and each owner's personal HNSW file.

**Solution**: route every mutation through the appropriate actor, which Swift's runtime serializes automatically.

---

## IndexQueue — Global Write Serializer

`Sources/Utilities/Database/IndexQueue.swift`

### Why it exists

`TableMutator` serializes PQ index writes, and `RegistryMutator` serializes registry writes, but a `putBatch` + concurrent `removeBatch` could still interleave at a higher level: the deletion ratio could spike past `TableMutator.compactThreshold` mid-ingestion, triggering a 20-minute HNSW compaction that blocks all subsequent mutations.

`IndexQueue` is the outermost serialization layer — it ensures that at most one heavy write operation (put OR remove) is in-flight at a time.

### Job types

```swift
private enum Job {
    case put([Seer.BatchPutItem], SeerRequest)
    case removeBatch([(documentId: String, ownerId: String)])
    case removeAll(ownerId: String, request: SeerRequest, CheckedContinuation<Int, Never>)
}
```

- `put` and `removeBatch` are **fire-and-forget** — callers return immediately, jobs run when the queue drains to them.
- `removeAll` is **awaitable** — suspends the caller until the job completes so the purge route handler can return an accurate `purgedCount`.

### Drain loop

```swift
private func drain() async {
    while !pending.isEmpty {
        let job = pending.removeFirst()
        recordDepth()
        await execute(job)   // ← actor suspension point; more jobs may arrive here
    }
    isProcessing = false
}
```

Actor reentrancy is the key: when `execute(job)` suspends (`await seer.putBatch(...)`), new jobs arriving from concurrent HTTP requests accumulate in `pending` on the actor's queue. When `execute` resumes, the `while` loop picks up the next job immediately — no polling, no sleep.

### `removeAll` continuation pattern

```swift
func removeAll(ownerId: String, request: SeerRequest) async -> Int {
    await withCheckedContinuation { continuation in
        enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
    }
}
```

The continuation is stored inside the `.removeAll` job. When `execute()` processes it:
```swift
case .removeAll(let ownerId, let request, let continuation):
    let count = await seer.removeAll(ownerId: ownerId, request: request)
    continuation.resume(returning: count)
```

The route handler that called `indexQueue.removeAll(...)` was suspended at `withCheckedContinuation`. It resumes with the accurate count only after the job actually completes — after all prior put/remove jobs in the queue have finished.

### Metrics

```swift
SeerMetrics.indexQueueDepth.record(Double(jobCount))
SeerMetrics.indexQueueItems.record(Double(itemCount))
```

Both are recorded before and after each job. When queue drains to empty, both are zeroed. Monitor `indexQueueDepth` in production — if it grows unbounded, ingestion is outpacing processing.

---

## TableMutator — PartitionTable Serializer

`Sources/Database/Mutators/TableMutator.swift`

Serializes all mutations to `PartitionTable` (global HNSW shard + PQ indices). Uses `SeerCache<PartitionTable>` for the in-memory snapshot and two separate `FilePersistence` files for topology vs. indices.

### Split file design (Phase 5)

Two files instead of one:
- `shard-<nodeId>-topology` — small JSON: just HNSW graph nodes, edges, entry point. Fast to load at startup.
- `shard-<nodeId>-indices` — large JSON: PQ codebooks and compressed partition embeddings. Loaded asynchronously after topology is ready.

This lets the server start serving HNSW searches before the full PQ index is available.

`PartitionTable` custom encoder **omits** `indices` — they're never written to the topology file. The migration decoder uses `decodeIfPresent` for the legacy embedded-indices format.

### WAL integration

```swift
private var wal:          HNSWTopologyWAL?       // nil = WAL unavailable, fall back
private var walByteCount: Int = 0
static let walCheckpointThreshold = 64 * 1024 * 1024  // 64 MB
```

After each mutation:
```swift
private func scheduleSave(draining table: inout PartitionTable) {
    let records = table.shard.pendingWALRecords  // drain the buffer
    table.shard.pendingWALRecords = []
    if let w = wal, !records.isEmpty {
        records.forEach { try? w.append($0) }
        walByteCount = w.byteSize
        if walByteCount >= Self.walCheckpointThreshold {
            scheduleCheckpoint()               // 5s debounce
        }
    } else {
        // WAL unavailable: 1s debounced full save
        tableDirty = true
        ...
    }
}
```

### Compaction trigger

```swift
static let compactThreshold: Double = 0.35

private func scheduleCompactIfNeeded() {
    let ratio = Double(stats.deletedNodes) / Double(total)
    guard ratio >= Self.compactThreshold else { return }
    compactTask = Task {
        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5s debounce
        _ = await self.compact()
    }
}
```

Called after every `remove()` and `removeAll()`. Only one `compactTask` runs at a time — the guard `compactTask == nil` prevents stacking.

### Vector store access pattern

```swift
// nonisolated: readable without actor hop from initializeTable()
nonisolated var vectorStore: HNSWVectorStore? {
    _vectorStore.withReadLock { $0 }
}
nonisolated func seedVectorStore(_ store: HNSWVectorStore) {
    _vectorStore.withWriteLock { $0 = store }
}
```

`_vectorStore` is `ReadWriteValue<HNSWVectorStore?>` — allows concurrent reads from search paths without hopping to the actor. Seeded once at startup before the actor queue is active.

### putBatch — no yields mid-batch

```swift
func putBatch(items: [...]) async {
    _ = await loadedTable()
    var table = cache.snapshot ?? PartitionTable()
    // Do NOT yield mid-batch.
    for (id, partitions, request) in items {
        table.put(id: id, partitions: partitions, ...)
    }
    cache.update(table)
    ...
}
```

The comment in source explains why: `store.nodeCount` (in `HNSWVectorStore`) increments in `put`. If a concurrent `putBatch` runs while this one is suspended mid-loop, both tasks read the same stale `store.nodeCount`, assigning overlapping `vectorIndex` values. A single uninterrupted loop keeps `nodes.count` and `store.nodeCount` in sync.

### Key methods

| Method | Behavior |
|--------|---------|
| `put(id:partitions:request:)` | Single document index — WAL + deferred save |
| `putBatch(items:)` | Batch index — no mid-loop yield — WAL + deferred save |
| `remove(id:)` | Single document remove — WAL drain + immediate checkpoint |
| `removeAll(documentIds:request:)` | Bulk remove — WAL drain + immediate checkpoint |
| `compact()` | Compact HNSW + rewrite vector file + checkpoint |
| `syncEf(efSearch:emaExplored:)` | Propagate adaptive ef into snapshot |
| `replace(with:)` | Full atomic replace (used by storage restore) |

---

## RegistryMutator — SeerRegistry Serializer

`Sources/Database/Mutators/RegistryMutator.swift`

Serializes all mutations to `SeerRegistry`. Uses `SeerCache<SeerRegistry>` backed by `FilePersistence(key: "registry")`.

### Debounced vs immediate saves

**Debounced (1s)**: `register()` and `registerBatch()` — called once per document during bulk indexing. Saving on every call would hold the actor for the full serialize+write duration, serializing all concurrent requests waiting on the actor. Instead, mutations are applied to the in-memory cache and a single background flush is scheduled.

**Immediate (`saveAsync`)**: `remove()`, `removeAll()`, `removeBatch()`, `updateDocumentAccess()`, `updateGroupAccess()`, `updateGroup()`, `renameGroup()`, `replace()` — correctness-critical operations where the change must survive a restart immediately.

```swift
private func scheduleSave() {
    registryDirty = true
    guard flushTask == nil else { return }         // coalesce — don't stack flush tasks
    flushTask = Task {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        self.flushIfDirty()
    }
}
```

The `flushTask == nil` guard coalesces many rapid `register()` calls into one disk write. A `replace()` cancels any pending flush task — the explicit save supersedes it.

### registerBatch — single actor invocation

```swift
func registerBatch(items: [(document:, group:, ownerId:)]) async {
    var registry = await loadedRegistry()    // one load
    for (document, group, ownerId) in items {
        // apply all mutations to local var
    }
    cache.update(registry)                   // one update
    scheduleSave()                           // one deferred flush
}
```

`registerBatch` loads the registry once, applies all mutations in a tight loop (no actor suspension), then schedules one deferred flush. This is significantly faster than calling `register()` N times, which would load-mutate-schedule N times (though each would be serialized by the actor).

### Earnings and performance accumulation

Both are debounced — called on every inference:

```swift
func accumulateEarnings(_ earnings: [DocumentID: Gita.Credits]) async {
    var registry = await loadedRegistry()
    registry.addEarnings(earnings)
    cache.update(registry)
    scheduleSave()       // coalesced with any pending register flush
}
```

The debounce means that 100 inferences per second produce at most 1 disk write per second to the registry file, not 100.

### nonisolated snapshot

```swift
nonisolated var snapshot: SeerRegistry? { cache.snapshot }
```

Route handlers that need to read registry state (e.g., for access control checks during search) call `tableMutator.snapshot` and `registryMutator.snapshot` — these are synchronous, require no actor hop, and use `ReadWriteValue`'s shared read lock. Multiple concurrent searches read the snapshot simultaneously without blocking each other or the mutator.

---

## PersonalHNSWMutator — Per-Owner Graph Serializer

`Sources/Database/Mutators/PersonalHNSWMutator.swift`

Manages N per-owner HNSW graphs. Each owner gets their own topology file, vector file, WAL, and `PersistenceActor`.

### Owner ID normalization

```swift
@inline(__always)
private func key(_ ownerId: String) -> String { ownerId.lowercased() }
```

Historical: some owner IDs were stored as uppercase UUIDs. All lookups go through `key()` to normalize to lowercase and hit the same cache entry. `Flow10_OwnerIdNormalizationTests.swift` tests this.

### Per-owner lazy resource creation

```swift
private var handles:      [String: FilePersistence]  = [:]
private var ioActors:     [String: PersistenceActor] = [:]
private var cache:        [String: HNSWGraph]        = [:]
private var vectorStores: [String: HNSWVectorStore]  = [:]
private var wals:         [String: HNSWTopologyWAL]  = [:]
```

All resources are created on first access, not at startup. A server with 1000 owners doesn't open 1000 vector files at boot — only the files for owners whose graphs are actually queried/modified.

### WAL per owner — 32 MB threshold

Each owner gets their own WAL file (`personal/<ownerId>-topology-wal`). Threshold is 32 MB (vs 64 MB for global). Personal graphs are smaller so the threshold is halved to keep checkpoint latency low.

### cachedGraph(for:) — the gate

Every mutation goes through `cachedGraph(for:)` first:

```swift
private func cachedGraph(for ownerId: String) async -> HNSWGraph {
    if let hit = cache[ownerId] { return hit }      // fast path
    var loaded: HNSWGraph = await io.restore() ?? HNSWGraph()
    
    // Phase 4: replay WAL before attaching vector store
    if let records = try? wal.readAll(), !records.isEmpty {
        for record in records { loaded.apply(record) }
    }
    
    // Attach vector store — detect Phase 3 migration
    if let store = vectorStore(for: ownerId, expectedNodeCount: loaded.nodes.count) {
        if store.wasCreatedFresh && !loaded.nodes.isEmpty {
            // Phase 3 migration: wipe topology
            loaded.nodes = []; loaded.partitionLookup = [:]
            loaded.entryPoint = -1; loaded.maxLevel = -1
        }
        loaded.vectorStore = store
    }
    
    // Re-check cache after await (concurrent mutation may have populated it)
    if let hit = cache[ownerId] { return hit }
    cache[ownerId] = loaded
    _snapshots.withWriteLock { $0[ownerId] = loaded }
    return loaded
}
```

WAL replay happens BEFORE attaching the vector store — the vector file already has data for WAL-replayed nodes (written during the original insert), but `nodeCount` must match the replayed topology so the store initializes correctly.

### addBatch — no yield mid-owner

```swift
func addBatch(items: [(partitions:, ownerId:)]) async {
    let ownerIds = Set(items.map { key($0.ownerId) })
    for ownerId in ownerIds { _ = await cachedGraph(for: ownerId) }  // warm cache
    
    var byOwner: [String: [Seer.Partition]] = [:]
    for (partitions, ownerId) in items { byOwner[key(ownerId), default: []].append(...) }
    
    var mutated: [String: HNSWGraph] = [:]
    for (i, (ownerId, partitions)) in byOwner.enumerated() {
        var graph = cache[ownerId] ?? HNSWGraph()
        for partition in partitions { graph.add(partition: partition) }  // no yield mid-owner
        mutated[ownerId] = graph
        if i % 5 == 4 { await Task.yield() }   // yield only between owners
    }
    ...
}
```

Yields only between owners, not mid-owner. Same reason as `TableMutator.putBatch`: `store.nodeCount` must stay consistent with `nodes.count` within a single owner's processing pass.

### Deletion is an immediate checkpoint

```swift
func removeBatch(documentIds: [DocumentID], for ownerId: String) async {
    ...
    vectorStores[ownerId]?.sync()
    Task.detached { await io.save(graph) }   // immediate
    try? wals[ownerId]?.truncate()           // WAL cleared
}
```

Deletions always checkpoint immediately. Design decision: correctness over latency. A deleted document must not appear in search results after restart, so the deletion must reach disk before the response returns.

### removeAll — file cleanup

```swift
func removeAll(for ownerId: String) {
    vectorStores.removeValue(forKey: ownerId)  // deinit → msync + munmap + close
    let vectorURL = baseURL.appendingPathComponent("personal/\(ownerId)-vectors")
    try? FileManager.default.removeItem(at: vectorURL)
    
    wals.removeValue(forKey: ownerId)          // deinit → close fd
    let walURL = baseURL.appendingPathComponent("personal/\(ownerId)-topology-wal")
    try? FileManager.default.removeItem(at: walURL)
    
    Task.detached { await io?.purge() }        // delete topology JSON
}
```

Removing the `HNSWVectorStore` from the dictionary triggers its `deinit`, which calls `msync`, `munmap`, and `close`. This is why `removeAll` doesn't need an explicit flush — the deinit handles it.

### nonisolated current(for:)

```swift
nonisolated func current(for ownerId: String) -> HNSWGraph? {
    _snapshots.withReadLock { $0[ownerId.lowercased()] }
}
```

`_snapshots` is `ReadWriteValue<[String: HNSWGraph]>`. This allows route handlers to read any owner's personal graph snapshot without hopping to the actor — essential for concurrent search performance. Multiple searches for different owners read simultaneously.

---

## PersistenceActor — Per-File I/O Serializer

`Sources/Utilities/Persistence/PersistenceActor.swift`

One actor per logical file. `FilePersistence.save` is not thread-safe — two concurrent calls on the same URL race on `data.write(to:)`. Wrapping in an actor gives serial execution without blocking any thread.

```swift
actor PersistenceActor {
    private let persistence: FilePersistence
    
    func save<T: Codable>(_ value: T) { persistence.save(state: value) }
    func restore<T: Codable>() -> T? { persistence.restore() }
    func purge() { persistence.purge() }
}
```

### Usage patterns

**`SeerCache<Value>.saveAsync()`** — detached task that hops to the actor:
```swift
func saveAsync(_ value: Value) {
    Task.detached { [io] in await io.save(value) }
}
```
The calling actor is freed immediately. Multiple rapid `saveAsync` calls queue behind each other in the actor — last-queued wins (each overwrites the prior). This is the correct behavior for checkpoint-style saves.

**`SeerCache<Value>.load(makeDefault:)`** — suspends calling actor during I/O:
```swift
func load(makeDefault: @Sendable () -> Value) async -> Value {
    if let hit = _store.withReadLock({ $0 }) { return hit }
    let restored: Value? = await io.restore()
    ...
}
```
Race-safe: if a concurrent invocation populates the cache while this call is suspended, the `_store.withWriteLock` CAS ensures only the first writer wins.

### Instances

| Location | File | Number |
|----------|------|--------|
| `TableMutator` | `shard-<nodeId>-topology` | 1 |
| `TableMutator` | `shard-<nodeId>-indices` | 1 |
| `RegistryMutator` | `registry` | 1 |
| `PersonalHNSWMutator` | `personal/<ownerId>` | N (one per owner) |
| `Sinatra` | `sinatra/registry` | 1 |
| `Gita` | `wallet_registry`, `gita/registry` | 2 |

---

## Actor Call Flow — Single Embed Request

```
POST /v1/embeddings
    │
    ├─ EmbeddingModelProvider.embed() → [Float]
    │
    ├─ IndexQueue.enqueuePut([BatchPutItem])   ← fire-and-forget
    │   │
    │   └─ (when queue drains to this job)
    │       ├─ seer.putBatch(items)
    │       │   ├─ RegistryMutator.registerBatch()    ← actor hop → mutate → deferred save
    │       │   ├─ TableMutator.putBatch()             ← actor hop → mutate → WAL append
    │       │   └─ PersonalHNSWMutator.addBatch()      ← actor hop → mutate → WAL append
    │       └─ Gita.track(.put)                        ← actor hop → royalty record
    │
    └─ Response → client (returned before IndexQueue drains)
```

The response returns as soon as the job is enqueued. The actual indexing happens in the background. This is intentional — embedding is fast (< 100ms), but HNSW insertion on a large graph can take hundreds of ms. The client doesn't wait.

---

## Rules for New Code

1. **Never mutate `SeerRegistry` directly** — always go through `RegistryMutator`. There is no legitimate reason to bypass it.

2. **Never mutate `PartitionTable` outside `TableMutator`** — the split-file persistence and WAL coordination only work because mutations are actor-serialized.

3. **Never call `personalHNSWMutator.cache[ownerId]` from outside the actor** — use `personalHNSWMutator.current(for:)` for reads (nonisolated, uses `_snapshots`).

4. **Use `IndexQueue` for all top-level put/remove operations** — not just for serialization but to prevent compaction spikes from firing mid-ingestion.

5. **Do not yield mid-batch within a single owner's processing pass** in `addBatch` or `putBatch` — the `nodes.count` / `store.nodeCount` invariant breaks on any yield.

6. **Deletions checkpoint immediately** — never use a deferred save for deletes. The user expects deleted data to stay deleted after restart.
