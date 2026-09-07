# Caching & Synchronization Primitives

Sewn's caching layer is built from four composable types that cover different scopes: per-request synchronous reads, generic persistent state, document identity lookup, and raw value protection. Understanding when to use each is critical to preserving the concurrency invariants that prevent data races at scale.

---

## Overview

```
ReadWriteValue<T>          — pthread_rwlock: concurrent reads, exclusive writes
LockedValue<T>             — NSLock: exclusive access for every operation
DocumentCache              — ReadWriteValue<[DocumentID: Sewn.Document]>
SewnCache<Value: Codable>  — ReadWriteValue<Value?> + PersistenceActor (disk)
PersistenceActor           — actor: serializes all disk I/O for one file
FilePersistence            — PropertyList encode/decode for one file
```

---

## ReadWriteValue\<T\>

**File**: `Sources/Utilities/Database/ReadWriteValue.swift`

### What it is

A POSIX reader-writer lock (`pthread_rwlock_t`) wrapper. Multiple callers can read simultaneously; writes are exclusive and block until all readers have released.

### When to use

Use `ReadWriteValue` for any value that is **read far more frequently than it is written** — the classic high-read/low-write pattern. The key examples in Sewn:

| Value | Read frequency | Write frequency |
|-------|---------------|----------------|
| HNSW graph snapshot | Every search request | Only on insert/delete/compact |
| Registry snapshot | Every embed, search, wallet query | On document register/delete |
| Personal HNSW snapshots map | Every personal graph search | On personal graph insert |
| DocumentCache store | Every document fetch | On index/delete |

### API

```swift
let rv = ReadWriteValue<[String: Int]>([:])

// Concurrent read — multiple callers run simultaneously
let count = rv.withReadLock { $0["key"] ?? 0 }

// Exclusive write — blocks until all readers release
rv.withWriteLock { $0["key"] = 42 }
```

### Implementation notes

- `pthread_rwlock_t` is available on both Apple platforms and Linux via `swift-corelibs-foundation` — no conditional compilation needed
- `deinit` calls `pthread_rwlock_destroy` — no leak
- The closure receives `T` (immutable) in read mode and `inout T` in write mode — mutation is impossible through the read path at the type level

### What NOT to use it for

Do not use `ReadWriteValue` for values that require atomic read-modify-write in a single lock acquisition with complex mutation logic that reads-then-writes. For those cases, use `withWriteLock` directly and do both the read and the write inside the same closure — do not call `withReadLock` followed by `withWriteLock` as separate calls (TOCTOU race).

---

## LockedValue\<T\>

**File**: `Sources/Utilities/Database/LockedValue.swift`

### What it is

An `NSLock`-based exclusive wrapper. Every caller, reader or writer, takes the same exclusive lock.

### When to use

Use `LockedValue` for values where:
1. Write operations are as frequent as reads, OR
2. You need a cross-platform `OSAllocatedUnfairLock`-compatible API in a context where the value isn't clearly read-heavy

In practice in Sewn, `ReadWriteValue` is preferred for all hot paths. `LockedValue` appears in lower-frequency state.

### API

```swift
let lv = LockedValue<Int>(0)
let result = lv.withLock { value -> Int in
    value += 1
    return value
}
```

---

## DocumentCache

**File**: `Sources/Utilities/Database/DocumentCache.swift`

### What it is

A `Sendable`, actor-free, thread-safe in-memory cache for `Sewn.Document` objects, backed by `ReadWriteValue<[DocumentID: Sewn.Document]>`.

Document reads are the most frequent operation in Sewn (every search result lookup, every royalty calculation). Routing them through an actor would add unnecessary queue hops. `DocumentCache` gives sub-microsecond concurrent reads with no actor overhead.

### Lifecycle

1. **Startup** — `Sewn.init` calls `seed(_:)` with the full map restored from `RegistryMutator`
2. **Index** — `cache(_:)` inserts one document (single write lock acquisition)
3. **Batch index** — `cacheBatch(_:)` inserts N documents in a **single** write lock acquisition (no N lock/unlock cycles)
4. **Lookup** — `get(_:)` concurrent read, lock held for microseconds
5. **Delete** — `evict(_:)` removes by ID

### API

```swift
// At startup
documentCache.seed(registry.allDocuments)

// On index
documentCache.cache(document)

// Batch (one lock acquisition)
documentCache.cacheBatch(documents)

// Lookup
let doc = documentCache.get(documentId)

// On delete
documentCache.evict(documentId)
```

### Key invariant

`DocumentCache` is always populated from `RegistryMutator.snapshot` at startup. They must stay in sync: any document registered in `RegistryMutator` must be cached in `DocumentCache`, and any deletion from the registry must call `evict`. The registry is the source of truth; the cache is a performance mirror.

---

## SewnCache\<Value\>

**File**: `Sources/Utilities/Database/SewnCache.swift`

### What it is

A generic, persistent, read-through cache for any `Codable & Sendable` value. Used by `TableMutator` (for `PartitionTable`) and `RegistryMutator` (for `SewnRegistry`).

Combines:
- `ReadWriteValue<Value?>` — concurrent in-memory reads
- `PersistenceActor` — serialized off-actor disk writes
- `FilePersistence` — PropertyList encode/decode to disk

### Methods

| Method | Thread safety | Blocking | When to call |
|--------|--------------|---------|-------------|
| `snapshot` | Read lock (concurrent) | No | Any time — hot path read |
| `seed(_:)` | Write lock (exclusive) | No | Startup, synchronous init |
| `update(_:)` | Write lock (exclusive) | No | After in-actor mutation, before saveAsync |
| `saveAsync(_:)` | Detached task → PersistenceActor | No (fire-and-forget) | After every mutation that needs persistence |
| `load(makeDefault:)` | Suspends calling actor | Yes (disk I/O) | First access from async context |
| `modify(makeDefault:_:)` | Write lock, atomic RMW | No | Atomic read-modify-write with no actor hop |
| `seedFromDisk(makeDefault:)` | Write lock + sync disk read | Yes (sync) | Startup before async context available |

### Typical actor usage pattern

```swift
// Inside TableMutator (actor):
func put(_ partition: Sewn.Partition) async {
    var table = cache.snapshot ?? PartitionTable()
    table.insert(partition)
    cache.update(table)          // update in-memory snapshot
    cache.saveAsync(table)       // kick off background disk write
}
```

### Load on first access

```swift
// Called once during Sewn startup
let table = await cache.load { PartitionTable() }
```

`load` suspends the calling actor while disk I/O completes, then caches the result. If two concurrent callers race, the first writer wins (idempotent — both would have loaded the same on-disk state).

### `modify` for atomic read-modify-write

```swift
// Inside RegistryMutator — atomic earnings accumulation
let updated = cache.modify(makeDefault: { SewnRegistry() }) { registry in
    registry.applyEarnings(earnings)
}
cache.saveAsync(updated)
```

The entire read-modify-write happens under one write lock. Never split this into `snapshot` + `update` with logic in between — that is a TOCTOU race if another actor call can interleave (actor reentrancy).

### `seedFromDisk` for synchronous init

```swift
// In synchronous init before the async world exists
let initial = cache.seedFromDisk { PartitionTable() }
```

Calls `FilePersistence.restore()` directly (synchronous) and seeds the `ReadWriteValue`. No actor hop. Safe only if called before the object is shared with any concurrent context.

---

## PersistenceActor

**File**: `Sources/Utilities/Persistence/PersistenceActor.swift`

### What it is

A Swift actor that wraps `FilePersistence` to serialize all disk I/O for a single file. `FilePersistence.save` and `FilePersistence.restore` are not thread-safe — two concurrent writes to the same URL race on `data.write(to:)` and on the `fileExists → createFile` branch. `PersistenceActor` eliminates the race without blocking any thread.

### One actor per file

| Instance location | File it guards |
|-------------------|---------------|
| `SewnCache<PartitionTable>` inside `TableMutator` | `shard-<nodeId>-topology` |
| `SewnCache<SewnRegistry>` inside `RegistryMutator` | `sewn-registry` |
| Per-owner `PersistenceActor` inside `PersonalHNSWMutator` | `personal-<ownerId>-topology` |
| Per-owner `PersistenceActor` for Sinatra | `sinatra-<ownerId>` |

**Never share one `PersistenceActor` between two files.** Create one per logical file.

### API

```swift
actor PersistenceActor {
    func save<T: Codable>(_ value: T)  // serialized write
    func restore<T: Codable>() -> T?  // serialized read (sees latest committed state)
    func purge()                       // deletes backing file
}
```

### `saveAsync` pattern

`SewnCache.saveAsync` uses:

```swift
func saveAsync(_ value: Value) {
    Task.detached { [io] in await io.save(value) }
}
```

- `Task.detached` releases the calling actor immediately — no suspension point in the calling actor
- The task hops to `PersistenceActor`'s serial executor — writes are ordered
- If `saveAsync` is called 10 times in rapid succession, all 10 writes are serialized through the actor queue; the last one committed to disk is the correct final state

### restore ordering guarantee

`PersistenceActor.restore()` waits for any in-flight `save()` to complete before reading. This means `load` always sees the latest committed state, even if called immediately after a `saveAsync`.

---

## FilePersistence

**File**: `Sources/Utilities/Persistence/FilePersistence.swift`

### What it is

Low-level read/write for one file. Uses `PropertyListEncoder/Decoder`. All Sewn state files (registry, table topology, Sinatra, Gita wallet) are stored as binary plists.

### Storage root

`FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]/sewn-db/`

In practice on a server: `~/.sewn/` (mapped at deployment via Docker volume).

### Key behaviors

- `save`: checks `fileExists` then either creates or overwrites. **Not thread-safe** — always wrap with `PersistenceActor`
- `restore`: decodes from disk; returns `nil` if file doesn't exist or data is corrupt (logs error)
- `purge`: `FileManager.removeItem` — no recovery, used for owner deletion

---

## Decision Guide: Which Primitive to Use

```
New value to protect:
│
├─ Is it a document identity lookup?
│   └─ YES → DocumentCache
│
├─ Does it need to survive process restarts?
│   └─ YES → SewnCache<Value>
│       ├─ reads >> writes?  → backed by ReadWriteValue internally ✓
│       └─ need atomic RMW?  → use cache.modify(...)
│
├─ Is it read far more than written (in-memory only)?
│   └─ YES → ReadWriteValue<T>
│
├─ Is it written as often as read OR logic is simple exclusive access?
│   └─ YES → LockedValue<T>
│
└─ Is it only accessed from inside a single actor?
    └─ YES → plain stored property (actor isolation is sufficient)
```

---

## Anti-patterns to Avoid

**1. Split read-modify-write across two lock calls**
```swift
// BAD — TOCTOU race if actor is reentrant
let current = cache.snapshot
current.insert(item)
cache.update(current)

// GOOD — single atomic RMW
cache.modify(makeDefault: { .init() }) { $0.insert(item) }
```

**2. Calling saveAsync then immediately restore without PersistenceActor**
```swift
// BAD — restore may see pre-save state
cache.saveAsync(value)
let v: PartitionTable? = FilePersistence(...).restore()  // races

// GOOD — always restore through the same PersistenceActor
let v: PartitionTable? = await io.restore()  // waits for in-flight save
```

**3. Sharing a PersistenceActor between multiple files**
```swift
// BAD — writes to different files serialize unnecessarily; worst-case
// restore of file A waits behind an unrelated save of file B
let shared = PersistenceActor(persistence: tableFile)
await shared.save(registryValue)  // saves to tableFile URL — wrong

// GOOD — one actor per file
let tableIO    = PersistenceActor(persistence: tableFile)
let registryIO = PersistenceActor(persistence: registryFile)
```

**4. Using LockedValue for high-read workloads**
```swift
// BAD — all search requests serialize behind each other
let cache = LockedValue<[DocumentID: Document]>([:])

// GOOD — concurrent reads in parallel
let cache = ReadWriteValue<[DocumentID: Document]>([:])
```

---

## Interaction with Actors (TableMutator, RegistryMutator)

`SewnCache` is not itself an actor — it is a `final class` held by an actor. The owning actor provides logical mutation serialization; `SewnCache` provides:
- Concurrent reads from outside the actor (via `snapshot`)
- Serialized disk writes regardless of which actor context triggers them

This design allows the hot-path read (`snapshot`) to bypass the actor queue entirely — a critical optimization when search is handling concurrent requests.

```
Search Request 1 ──→ partitionTable.snapshot ──→ ReadWriteValue.withReadLock ──→ PartitionTable (concurrent)
Search Request 2 ──→ partitionTable.snapshot ──→ ReadWriteValue.withReadLock ──→ PartitionTable (concurrent)
Index Request    ──→ TableMutator (actor hop) ──→ cache.update + cache.saveAsync
                                                         └──→ PersistenceActor (serial disk write)
```

No request blocks another on reads. Only disk writes and HNSW mutations are serialized.
