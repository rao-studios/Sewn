# Concurrency — The Write Queue, RegistryMutator, PersistenceActor

Sewn's write path is serialized through a very small set of concurrency
primitives. There are three, and that is the whole story:

| Primitive | Where | Serializes |
|-----------|-------|-----------|
| `Sewn`'s `WriteJob` FIFO queue | `Sources/Core/Sewn.swift` | Every index mutation (put / remove / removeAll) |
| `RegistryMutator` (actor) | `Sources/Core/Mutators/RegistryMutator.swift` | Billing-stat writes and Thread node tracking |
| `PersistenceActor` (actor) | `Sources/Utilities/Persistence/PersistenceActor.swift` | Disk I/O for one file |

> **Historical note.** `TableMutator`, `PersonalHNSWMutator`, and the standalone
> `IndexQueue` actor are gone. They existed to protect a local HNSW graph and PQ
> index; both moved to Thread. The `IndexQueue`'s job — one heavy write in flight
> at a time — now lives inside the `Sewn` actor as the `WriteJob` queue.
> `PersistenceActor`'s own doc comment still mentions `PersonalHNSWMutator`;
> that reference is stale in the source.

---

## The Core Problem: Last-Write-Wins

Without serialization, concurrent writes to the same persisted state produce
this race:

```
Request A:  load registry → mutate → save registry [A's version]
Request B:            load registry → mutate → save registry [B's version, overwrites A]
```

A's mutation is silently dropped. No error, no panic, no log. For billing state
that means an owner's earnings quietly fail to accumulate.

The fix is uniform: route every mutation through an actor, which Swift's runtime
serializes for you.

---

## The WriteJob Queue

`Sources/Core/Sewn.swift`

```swift
private enum WriteJob {
    case put([Sewn.BatchPutItem], SewnRequest)
    case removeBatch([(documentId: String, ownerId: String)])
    case removeAll(ownerId: String, request: SewnRequest, CheckedContinuation<Int, Never>)
}
private var pending: [WriteJob] = []
private var isProcessing = false
```

### Why it exists

Actor isolation alone is not enough. `putBatch` and `removeBatch` both fan out to
Thread, and a `removeBatch` that interleaves mid-`putBatch` can remove documents
the put is still writing — Thread would see the operations out of order. The
queue provides the ordering guarantee: **at most one heavy write in flight, in
submission order.**

### Public API

```swift
func enqueuePut(_ items: [Sewn.BatchPutItem], request: SewnRequest)        // fire-and-forget
func enqueueRemoveBatch(_ items: [(documentId: String, ownerId: String)])  // fire-and-forget
func removeAll(ownerId: String, request: SewnRequest) async -> Int         // awaitable
```

`put` and `removeBatch` return immediately; the job runs when the queue drains to
it. `removeAll` suspends the caller so a purge handler can return an accurate
count.

### The drain loop and put coalescing

```swift
private func enqueue(_ job: WriteJob) {
    pending.append(job)
    SewnMetrics.indexQueueDepth.record(Double(pending.count))
    guard !isProcessing else { return }   // ← a second drain can never start
    isProcessing = true
    Task { await self.drain() }
}
```

`drain()` does something the old `IndexQueue` did not: it **merges consecutive
put jobs**.

```swift
private static let maxCoalesceItems = 100

// inside drain():
if case .put(let firstItems, let baseReq) = pending[0] {
    var merged = firstItems
    var consumed = 1
    while consumed < pending.count && merged.count < Self.maxCoalesceItems {
        guard case .put(let nextItems, let nextReq) = pending[consumed],
              nextReq.ownerId == baseReq.ownerId,
              nextReq.group?.id == baseReq.group?.id else { break }
        merged.append(contentsOf: nextItems)
        consumed += 1
    }
    pending.removeFirst(consumed)
    await execute(.put(merged, baseReq))
}
```

Three constraints hold the merge together, and all three matter:

1. **Same `ownerId`** — a merged job carries one `SewnRequest`, so mixing owners
   would attribute documents to the wrong person.
2. **Same `group.id`** — likewise for group placement.
3. **`maxCoalesceItems = 100`** — bounds the fan-out payload. gRPC accepts up to
   100 MB, but a single unbounded batch would also hold the queue for its whole
   duration.

The loop `break`s rather than skipping, so ordering is never reordered — a
`removeBatch` between two puts stops the merge.

### Actor reentrancy is the mechanism

When `execute(job)` suspends on a fan-out, new jobs arriving from concurrent HTTP
requests accumulate in `pending` on the actor's queue. They cannot execute,
because `isProcessing` is still `true`. When `execute` resumes, the `while` loop
picks up the next job immediately — no polling, no sleep.

### The removeAll continuation

```swift
func removeAll(ownerId: String, request: SewnRequest) async -> Int {
    await withCheckedContinuation { continuation in
        enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
    }
}
```

The continuation travels inside the job. `execute` resumes it only after the work
actually completes — after every earlier job in the queue has finished.

> Note the current return value: `_removeAll` broadcasts
> `fanoutRemove(documentIds: [], ownerId:)` and returns **0**, because Sewn no
> longer keeps a local document list to count. Thread does the filtering. Any
> caller that reports a purged count to a user is reporting zero.

### Metrics

`SewnMetrics.indexQueueDepth` (`sewn.index.queue_depth`) is recorded on every
enqueue and every dequeue, and zeroed when the queue drains. If it grows without
bound, ingestion is outpacing Thread. `sewn.index.queue_items` tracks item count.

---

## RegistryMutator

`Sources/Core/Mutators/RegistryMutator.swift`

Two responsibilities, which is worth internalizing because the name suggests one:

1. **Billing stats** — `SewnRegistry.documentStats` earnings and performance.
2. **Thread node tracking** — the live fleet used for fan-out routing.

Document, group, and ownership data is **not** here. Thread owns it.

### The WAL is the durability mechanism

Billing writes are hot-path: every inference accumulates earnings and
performance. Rewriting the whole property list each time would be absurd, so
mutations append a small binary record instead.

```swift
static let walCheckpointThreshold = 16 * 1024 * 1024   // 16 MB

private func appendWAL(_ record: RegistryWALRecord) {
    if let w = wal {
        try? w.append(record)
        walByteCount = w.byteSize
        if walByteCount >= Self.walCheckpointThreshold { checkpoint() }
    } else {
        scheduleSave()      // ← WAL unavailable: fall back to a debounced full save
    }
}
```

So the flow is:

```
accumulateEarnings / accumulatePerformance
    │
    ├─ loadedRegistry()          — cache.load, first access only
    ├─ registry.addEarnings(…)   — mutate the local copy
    ├─ cache.update(registry)    — in-memory snapshot is now current
    └─ appendWAL(record)         — durability, ~bytes not megabytes
            │
            └─ WAL ≥ 16 MB → checkpoint(): saveNow + truncate WAL
```

Note what is **absent**: `accumulateEarnings` does not call `scheduleSave()` when
a WAL exists. The in-memory snapshot plus the WAL *is* the durable state. Startup
replays the WAL on top of the last checkpoint.

### checkpoint() and flushForShutdown()

```swift
private func checkpoint() {
    guard let registry = cache.snapshot else { return }
    walByteCount = 0; registryDirty = false
    flushTask?.cancel(); flushTask = nil
    let capturedWal = wal
    Task {
        await self.cache.saveNow(registry)
        try? capturedWal?.truncate()
    }
}
```

Order matters: **save, then truncate.** Truncating first would lose every
mutation since the last checkpoint if the save failed.

`flushForShutdown()` is the same sequence but awaited, and `Sewn.shutdown()`
calls it. Skipping a clean shutdown is survivable — the WAL replays — but it
leaves work for startup.

### The debounced fallback

Used only when the WAL could not be opened:

```swift
private func scheduleSave() {
    registryDirty = true
    guard flushTask == nil else { return }   // coalesce; don't stack flush tasks
    flushTask = Task {
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        self.flushIfDirty()
    }
}
```

The `flushTask == nil` guard collapses many rapid mutations into one disk write
per second. Note the `catch { return }` — a cancelled sleep does **not** flush.

### nonisolated snapshot

```swift
nonisolated var snapshot: SewnRegistry? { cache.snapshot }
nonisolated func seed(_ initial: SewnRegistry) { cache.seed(initial) }
```

Route handlers that only read billing stats call `snapshot` — synchronous, no
actor hop, a shared read lock inside `ReadWriteValue`. Many concurrent requests
read simultaneously without blocking each other or the mutator.

### Thread node tracking

```swift
private var nodes: [UUID: ThreadNode] = [:]
private var ownerThreadMap: [String: Set<UUID>] = [:]
```

| Method | Behavior |
|--------|----------|
| `registerNode(_:)` | Stores the node; applies `THREAD_HOST_OVERRIDE` when set; evicts a stale entry for the same host/port |
| `heartbeatNode(threadId:)` | Refreshes `lastSeen` |
| `updateNodeAvailability(threadId:accepting:)` | Toggles `acceptingStorage` |
| `removeNode(threadId:)` | Session closed |
| `threadNode(for:)` | Returns the node **only if active** |
| `activeNodes` / `availableForStorage` / `allNodes` | Fan-out target sets |
| `recordOwnerThread(ownerId:threadId:)` | Owner → node affinity after a successful index |
| `threadNodesForOwner(_:allNodes:)` | Affinity lookup; falls back to all nodes when unknown |

Nodes unseen for **300 seconds** are stale.

---

## PersistenceActor

`Sources/Utilities/Persistence/PersistenceActor.swift`

One actor per logical file. `FilePersistence.save` is not thread-safe — two
concurrent calls on the same URL race on `data.write(to:)` and on the
`fileExists → createFile` branch. The actor gives serial execution without
blocking a thread.

```swift
actor PersistenceActor {
    func save<T: Codable>(_ value: T)     // serialized write
    func restore<T: Codable>() -> T?      // serialized read, sees the latest committed state
    func purge()                          // deletes the backing file
}
```

`restore()` runs on the same executor as `save()`, so it waits for any in-flight
save — `load` after a `saveAsync` always sees the newer value.

### Live instances

| Owner | File |
|-------|------|
| `SewnCache<SewnRegistry>` in `RegistryMutator` | `registry` |
| `SewnCache<SinatraRegistry>` in `Sinatra` | `sinatra/registry` |
| `Gita` | `wallet_registry` (via `FilePersistence` directly) |
| `Sewn.Document` / conversation helpers | `documents/{id}`, `conversations/{id}` |
| `Personality` | `personalities` |

**Never share one `PersistenceActor` between two files.** A restore of file A
would queue behind an unrelated save of file B.

---

## Actor Call Flow — One Index Request

```
POST /v1/embeddings
    │
    ├─ TextChunker + TagGenerator          (synchronous, no actor)
    │
    ├─ await sewn.enqueuePut(items, request:)     ← fire-and-forget
    │   │
    │   └─ (when the FIFO drains to this job, possibly merged with neighbours)
    │       ├─ putBatch(items, request:)
    │       │   └─ fanoutIndex(partitions:request:)   → ONE Thread node
    │       │        └─ on success: registryMutator.recordOwnerThread(…)
    │       └─ gita.track(.put)
    │
    └─ Response already sent to the client
```

Embedding, PQ training, and HNSW insertion all happen on the Thread node. Sewn's
share of the work is chunking, tagging, placement, and remembering where it went.

---

## Rules for New Code

1. **Route every index mutation through `enqueuePut` / `enqueueRemoveBatch` /
   `removeAll`.** Calling `putBatch` or `_removeBatch` directly bypasses the
   ordering guarantee.
2. **Never mutate `SewnRegistry` outside `RegistryMutator`.** There is no
   legitimate reason to.
3. **Every new billing mutation needs a `RegistryWALRecord` case and WAL replay
   handling.** Mutating `cache` without appending to the WAL produces state that
   silently vanishes on restart.
4. **Checkpoint order is save-then-truncate.** Never the reverse.
5. **One `PersistenceActor` per file.**
6. **Read hot paths through `nonisolated` snapshots,** not by hopping to the
   actor.
7. **Preserve the coalescing constraints.** If you widen the merge in `drain()`,
   `ownerId` and `group.id` equality are what keep documents attributed
   correctly.
