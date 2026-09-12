# Caching & Synchronization Primitives

Sewn's caching layer is five composable types covering different scopes:
concurrent in-memory reads, exclusive in-memory access, document identity
lookup, persistent state, and serialized disk I/O. Choosing the right one is how
the hot read paths avoid actor hops without introducing races.

---

## Overview

```
ReadWriteValue<T>          — pthread_rwlock: concurrent reads, exclusive writes
LockedValue<T>             — NSLock: exclusive access for every operation
DocumentCache              — ReadWriteValue<[DocumentID: Sewn.Document]>
SewnCache<Value: Codable>  — ReadWriteValue<Value?> + PersistenceActor
PersistenceActor           — actor: serializes all disk I/O for ONE file
FilePersistence            — PropertyList encode/decode for one file
```

Files: `Sources/Utilities/Database/` (the first four),
`Sources/Utilities/Persistence/` (the last two).

---

## ReadWriteValue\<T\>

**File**: `Sources/Utilities/Database/ReadWriteValue.swift`

A POSIX reader-writer lock (`pthread_rwlock_t`) wrapper. Multiple callers read
simultaneously; writes are exclusive and block until all readers release.

```swift
final class ReadWriteValue<T>: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    func withReadLock<R>(_ body: (T) -> R) -> R          // shared
    func withWriteLock<R>(_ body: (inout T) -> R) -> R   // exclusive
}
```

### When to use

Any value read far more often than written. In Sewn:

| Value | Read frequency | Write frequency |
|-------|---------------|----------------|
| `SewnRegistry` snapshot (billing stats) | Every wallet query, every leaderboard build | On earnings/performance accumulation |
| `SinatraRegistry` snapshot | Every turn's tone lookup | On training |
| `DocumentCache` store | Every document metadata fetch | On index / delete |

### Implementation notes

- `pthread_rwlock_t` exists on Apple platforms and on Linux via
  swift-corelibs-foundation — no conditional compilation.
- `deinit` calls `pthread_rwlock_destroy`.
- The read closure receives `T`, the write closure `inout T`. Mutation through
  the read path is impossible at the type level.

### What NOT to use it for

Do not split a read-modify-write across two calls. `withReadLock` followed by
`withWriteLock` is a TOCTOU race — another writer can land in the gap. Do both
inside one `withWriteLock`, or use `SewnCache.modify`.

---

## LockedValue\<T\>

**File**: `Sources/Utilities/Database/LockedValue.swift`

```swift
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    func withLock<R>(_ body: (inout T) -> R) -> R
}
```

Exclusive for readers and writers alike. `NSLock` is chosen over
`OSAllocatedUnfairLock` for cross-platform availability. Use it when writes are
about as frequent as reads, or when the access pattern is a simple exclusive
read-modify-write. `ReadWriteValue` is preferred on every hot read path.

---

## DocumentCache

**File**: `Sources/Utilities/Database/DocumentCache.swift`

```swift
final class DocumentCache: Sendable {
    func get(_ id: DocumentID) -> Sewn.Document?
    func cache(_ document: Sewn.Document)
    func cacheBatch(_ documents: [Sewn.Document])   // ONE write-lock acquisition
    func evict(_ id: DocumentID)
    func seed(_ initial: [DocumentID: Sewn.Document])
}
```

A `Sendable`, actor-free, thread-safe map of `Sewn.Document`, backed by
`ReadWriteValue`. Document metadata reads happen on every royalty calculation and
every reference resolution; routing them through an actor would add a queue hop
for a dictionary lookup.

`cacheBatch` exists specifically to avoid N lock/unlock cycles during bulk
indexing.

Held by the `Sewn` actor as a `let`, so it is reachable `nonisolated`.

---

## SewnCache\<Value\>

**File**: `Sources/Utilities/Database/SewnCache.swift`

```swift
final class SewnCache<Value: Codable & Sendable>: @unchecked Sendable
```

A generic persistent read-through cache, combining:

- `ReadWriteValue<Value?>` — concurrent in-memory reads
- `PersistenceActor` — serialized off-actor disk writes
- `FilePersistence` — property-list encode/decode

Used by `RegistryMutator` (for `SewnRegistry`) and `Sinatra` (for
`SinatraRegistry`).

### Methods

| Method | Thread safety | Blocking | When to call |
|--------|--------------|---------|-------------|
| `snapshot` | Shared read lock | No | Any time — hot-path read |
| `seed(_:)` | Write lock | No | Startup |
| `update(_:)` | Write lock | No | After an in-actor mutation |
| `saveAsync(_:)` | Detached task → `PersistenceActor` | No | Fire-and-forget checkpoint |
| `saveNow(_:)` | Awaits the `PersistenceActor` | Yes | Checkpoint and shutdown, where the write must land before proceeding |
| `load(makeDefault:)` | Suspends the caller | Yes (disk) | First access from an async context |
| `modify(makeDefault:_:)` | Write lock, atomic RMW | No | Atomic read-modify-write with no actor hop |
| `seedFromDisk(makeDefault:)` | Write lock + sync disk read | Yes (sync) | Synchronous `init`, before any async context exists |

### Typical actor usage

```swift
// Inside RegistryMutator (actor):
func accumulateEarnings(_ earnings: [DocumentID: Gita.Credits]) async {
    guard !earnings.isEmpty else { return }
    var registry = await loadedRegistry()   // cache.load, first access only
    registry.addEarnings(earnings)
    cache.update(registry)                  // in-memory snapshot now current
    appendWAL(.earningsAccumulated(...))    // durability via WAL, not a full save
}
```

Note that the durable write here is the **WAL append**, not `saveAsync`. See
`Skills/Concurrency/README.md`.

### saveNow vs saveAsync

`saveAsync` uses `Task.detached`, so the calling actor is freed immediately and
the write is ordered behind any other write on that file's `PersistenceActor`.
`saveNow` awaits it. `RegistryMutator.checkpoint()` and `flushForShutdown()` use
`saveNow` because the WAL is truncated afterwards — the save must be committed
before the log that could reconstruct it is discarded.

### modify for atomic read-modify-write

```swift
let updated = cache.modify(makeDefault: { SewnRegistry() }) { registry in
    registry.addEarnings(earnings)
}
```

The whole read-modify-write happens under one write lock. Never split this into
`snapshot` + mutate + `update` when another actor call can interleave — actors
are reentrant across suspension points.

### seedFromDisk for synchronous init

Calls `FilePersistence.restore()` synchronously and seeds the `ReadWriteValue`.
Safe only before the object is shared with any concurrent context — which is
exactly the case in a synchronous `init`.

---

## PersistenceActor

**File**: `Sources/Utilities/Persistence/PersistenceActor.swift`

```swift
actor PersistenceActor {
    func save<T: Codable>(_ value: T)
    func restore<T: Codable>() -> T?
    func purge()
}
```

One actor per logical file. `FilePersistence.save` is not thread-safe: two
concurrent calls on the same URL race on `data.write(to:)` and on the
`fileExists → createFile` branch. The actor removes the race without blocking a
thread.

`restore()` shares the executor with `save()`, so it waits for any in-flight
save — a `load` immediately after a `saveAsync` sees the newer value.

**Never share one `PersistenceActor` between two files.** A restore of file A
would queue behind an unrelated save of file B.

> The type's doc comment still cites `PersonalHNSWMutator` as an owner. That
> actor no longer exists; the comment is stale in the source.

---

## FilePersistence

**File**: `Sources/Utilities/Persistence/FilePersistence.swift`

Low-level read/write for one file, using `PropertyListEncoder` /
`PropertyListDecoder`. Every Sewn state file is a binary property list — **not
JSON**, which matters if you plan to inspect one by hand.

### Storage root

```
~/Documents/sewn-db            # default
--data-dir <path>              # wins over the environment
SEWN_DATA_DIR=<path>           # environment fallback
```

Tilde is expanded and the directory is created at startup.
`FilePersistence.getDefaultURL()` is the single source of that path; every
`FilePersistence`, the registry WAL (`registry-wal`), and the node identity live
under it. Mary launches Sewn with `--data-dir ~/Documents/MaryOS/sewn-db`;
Docker maps a volume onto the default.

### Keys in use

| Key | Owner |
|-----|-------|
| `registry` | `RegistryMutator` |
| `wallet_registry` | `Gita` |
| `sinatra/registry` | `Sinatra` |
| `documents/{id}` | `Sewn.Document` |
| `conversations/{id}` | Conversation history |
| `personalities` | `Personality` |

### Key behaviors

- `save`: checks `fileExists`, then creates or overwrites. **Not thread-safe** —
  always wrap with `PersistenceActor`.
- `restore`: returns `nil` if the file is missing or the data is corrupt, and
  logs the error. Callers must have a default.
- `purge`: `FileManager.removeItem`, no recovery. Used for owner deletion.

---

## Decision Guide

```
New value to protect:
│
├─ Is it document metadata by id?
│   └─ YES → DocumentCache
│
├─ Must it survive process restart?
│   └─ YES → SewnCache<Value>
│       ├─ hot-path mutation?  → pair it with a WAL record (see Concurrency)
│       └─ need atomic RMW?    → cache.modify(...)
│
├─ Read far more than written, in memory only?
│   └─ YES → ReadWriteValue<T>
│
├─ Written about as often as read, or simple exclusive access?
│   └─ YES → LockedValue<T>
│
└─ Only ever touched from inside one actor?
    └─ YES → a plain stored property. Actor isolation is enough.
```

---

## Anti-patterns

**1. Split read-modify-write across two lock calls**
```swift
// BAD — TOCTOU race across the suspension point
var current = cache.snapshot ?? .init()
current.addEarnings(earnings)
cache.update(current)

// GOOD — one atomic RMW
cache.modify(makeDefault: { .init() }) { $0.addEarnings(earnings) }
```

**2. Restoring outside the owning PersistenceActor**
```swift
// BAD — may see pre-save state
cache.saveAsync(value)
let v: SewnRegistry? = FilePersistence(key: "registry", kind: .basic, logger: l).restore()

// GOOD — same actor, so the read waits for the write
let v = await cache.load { .init() }
```

**3. Truncating a WAL before the checkpoint save completes**
```swift
// BAD — a failed save loses everything since the last checkpoint
try? wal?.truncate()
cache.saveAsync(registry)

// GOOD — save, then truncate
await cache.saveNow(registry)
try? wal?.truncate()
```

**4. LockedValue on a high-read path**
```swift
// BAD — every reader serializes
let cache = LockedValue<[DocumentID: Sewn.Document]>([:])

// GOOD — concurrent reads
let cache = ReadWriteValue<[DocumentID: Sewn.Document]>([:])
```

---

## Why SewnCache Is Not Itself an Actor

`SewnCache` is a `final class` held *by* an actor. The owning actor provides
logical mutation serialization; `SewnCache` provides two things the actor cannot:

- concurrent reads from **outside** the actor, via `snapshot`
- serialized disk writes regardless of which actor triggered them

That split is what lets the hot read path bypass the actor queue entirely:

```
Wallet request 1 ──→ registryMutator.snapshot ──→ withReadLock ──┐
Wallet request 2 ──→ registryMutator.snapshot ──→ withReadLock ──┼─→ concurrent
Leaderboard      ──→ registryMutator.snapshot ──→ withReadLock ──┘

Inference        ──→ RegistryMutator (actor hop) ──→ cache.update + appendWAL
                                                     └──→ PersistenceActor (serial write)
```

No read blocks another. Only mutations and disk writes serialize.
