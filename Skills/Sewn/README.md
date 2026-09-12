# Sewn — The Orchestration Layer

`Sewn` is an actor, not a database. It owns no vectors, no HNSW graph, and no
knowledge graph. What it owns is the **composition** of a turn: resolve who is
asking, start sentiment and retrieval together, compact what came back, assemble
the prompt, pick the backend, attribute the answer, price it, and bank the
earnings.

Source: `Sources/Core/`

---

## Shape of the Actor

```
Sewn (actor)                       Sources/Core/Sewn.swift
  ├── sinatra: Sinatra             — per-owner GBT tone model
  ├── gita: Gita                   — royalty shares, spans, wallet
  ├── registryMutator              — billing stats + LIVE THREAD NODE REGISTRY
  ├── documentCache: DocumentCache — lock-free document identity lookup
  ├── nodeId: UUID                 — stable mothership identity (NodeIdentity)
  ├── _threadQueryClient           — type-erased ThreadQueryClient, nil until a node registers
  └── pending: [WriteJob]          — the single FIFO write queue
```

### File map

| File | Contents |
|------|----------|
| `Sewn.swift` | The actor, `handleChat`, the write queue and its drain loop |
| `Sewn+ThreadFanout.swift` | Every `fanout*` primitive — the only way out to Thread |
| `Commands/Sewn+Search.swift` | `search(_:request:topK:)` → `searchWithThreads` |
| `Commands/Sewn+Put.swift` | `BatchPutItem`, `putBatch` |
| `Commands/Sewn+Remove.swift` | `_removeAll`, `_removeBatch` |
| `Commands/Sewn+Compact.swift` | Briefing compaction, `CompactResult`, citation seeds |
| `Commands/Sewn+QueryExpander.swift` | `expandQuery` — **currently original-only** |
| `Commands/Sewn+Get.swift` | Document envelope read from disk |
| `Sewn+AutoMemory.swift` | Auto-memory triggers and policy |
| `Sewn+Infinite.swift` | Public-group leaderboard and search |
| `Sewn+Registry.swift` | `registry` snapshot, fire-and-forget billing accumulation |
| `Sewn+Marielle.swift` | Marielle candidate selection — **routes return 503** |
| `Sewn+Utilities.swift` | Content hashing (document CID), helpers |
| `Mutators/RegistryMutator.swift` | The one mutator actor |

---

## The Write Queue

Every index mutation goes through one FIFO drain inside the actor. See
`Skills/Concurrency/README.md` for the full mechanics; the API surface is:

```swift
func enqueuePut(_ items: [Sewn.BatchPutItem], request: SewnRequest)          // fire-and-forget
func enqueueRemoveBatch(_ items: [(documentId: String, ownerId: String)])    // fire-and-forget
func removeAll(ownerId: String, request: SewnRequest) async -> Int           // awaitable
```

Consecutive `.put` jobs with the same `ownerId` and `group.id` coalesce into one
job, up to `maxCoalesceItems = 100`.

---

## Search

```swift
nonisolated func search(_ query: String?,
                        request: SewnRequest,
                        topK: Int = 3,
                        enableSinatraPark: Bool = true) async throws -> SearchChatResult
```

An empty query returns an empty result rather than erroring. With a Thread client
attached it delegates to `searchWithThreads`; with none, there is nowhere to
search.

**Sewn passes raw query text, not a vector.** Each Thread embeds locally, which
is why Sewn needs no embedding model on the retrieval path at all:

```
search(query)
  │
  ├─ fanoutSearch(queryText:request:topK:)
  │   ├─ Build Thread_V1_ThreadSearchRequest
  │   │    queryText, entities (request.entities ?? request.tags),
  │   │    ownerID, scope (default "global"), topK,
  │   │    groupIds (request.groups + request.group), aggregate
  │   ├─ withTaskGroup: one task per ACTIVE node
  │   ├─ Thread: entity match → graph expansion → HNSW → PQ re-rank
  │   └─ Merge partition results; union the graph trace
  │        (entity matches deduped, expansion edges unioned)
  │
  ├─ Sort by score, de-duplicate, truncate to topK
  ├─ Gita.track(.inference) → unpriced word-count shares
  └─ Sinatra park (when enableSinatraPark) — partitions await the user's NEXT reply
```

A node that throws is logged and skipped. Partial results from the surviving
nodes are still merged — a dead node degrades recall, it does not fail the turn.

---

## Compaction — `Sewn+Compact.swift`

Retrieved partitions are usually summarized into a **briefing** by an LLM pass
before being handed to the chat model. That pass is the dominant pre-stream cost
(measured around 12 s at 30 partitions), so there is a bypass:

```swift
static let verbatimContextThreshold = 6000   // total partition characters
```

At or under 6000 characters, context is injected **verbatim** and no briefing
call is made. The `[n]` tag protocol never required the LLM.

`CompactResult` carries three things forward:

| Field | Purpose |
|-------|---------|
| `text` | The briefing (or the verbatim context) |
| `citations` | Per-partition citation key words — the **highest-confidence span seed** for `Gita.computeSpans` |
| tag → document id map | Bracket-tag number → source document, in exactly the order the `[n]` tags were rendered |

On the verbatim path `citations` is empty, so span attribution degrades to the
marker tier and then the heuristic tier. That is a real quality difference worth
remembering when debugging attribution: **small retrievals produce weaker spans.**

---

## Auto-Memory — `Sewn+AutoMemory.swift`

Snapshots of a conversation are indexed back into the owner's corpus when a
trigger fires.

```swift
enum AutoMemoryTrigger: Hashable {
    case messageCount(threshold: Int = 7)   // every time user message count crosses a multiple
    case topicChange                        // Sinatra session boundary (pace + attentiveness collapse)
}

enum AutoMemoryPolicyMode { case any, all } // OR vs AND across active triggers
```

`.any` fires when at least one active trigger fires; `.all` requires every active
trigger simultaneously and scales past two triggers. The snapshot is written via
`enqueuePut`, so it joins the same FIFO queue as ordinary indexing.

Auto-memory runs a generation of its own, which means it follows the turn's
provider — on `local` it is **off** unless `SEWN_LOCAL_UTILITY=1`.

---

## Query Expansion — currently a no-op

```swift
/// Expands a user message with passages from the owner's resonance group.
/// With Thread-only storage, resonance variants are not available locally — returns original-only.
```

`expandQuery` still exists and is still called, but it returns `original`-only.
Re-enabling it means fetching resonance-group passages over Thread fan-out.
Don't document it as working expansion; it isn't.

---

## Billing Accumulation — `Sewn+Registry.swift`

Two fire-and-forget paths write into `SewnRegistry`, both deliberately off the
response path:

```swift
nonisolated func accumulatePerformance(_ updates: [DocumentID: Sewn.DocumentStats])
nonisolated func accumulateEarnings(from contribution: Gita.Contribution, threadIds: [String] = [])
```

`accumulateEarnings` short-circuits when `contribution.totalCost == 0`, converts
the contribution into per-document earnings via `gita.documentEarnings(from:)`,
and hands them to `RegistryMutator.accumulateEarnings`. Both spawn a detached
`Task` — the caller never waits for a disk write to return a chat response.

The registry snapshot is available synchronously:

```swift
nonisolated var registry: SewnRegistry? { registryMutator.snapshot }
```

---

## Infinite — `Sewn+Infinite.swift`

The public-group leaderboard. Composite activity score, min-max normalized
across all public groups **at request time** — no score is persisted:

| Component | Weight |
|-----------|--------|
| Earnings | 40% |
| Retrieval count | 30% |
| Average sentiment | 20% |
| Document count | 10% |

`GroupMetrics.averageSentiment` returns `sentimentSum / retrievalCount`, or
`0.5` when the group has never been retrieved — a neutral prior, not a zero.

Routes: `GET /v1/infinite/leaderboard` (`page`, `page_size` clamped to 1–100,
default 20), `POST /v1/infinite/search`.

---

## Thread Node Registry lives in RegistryMutator

This surprises people: the live node list is not a separate service.
`RegistryMutator` holds both the billing registry and the Thread fleet.

```swift
func registerNode(_ node: ThreadNode)
func heartbeatNode(threadId: UUID)
func updateNodeAvailability(threadId: UUID, accepting: Bool)
func removeNode(threadId: UUID)
func threadNode(for threadId: UUID) -> ThreadNode?   // nil unless ACTIVE
var activeNodes: [ThreadNode]
var availableForStorage: [ThreadNode]
var allNodes: [ThreadNode]

// Owner → node affinity, so indexed documents can be found again
func recordOwnerThread(ownerId: String, threadId: UUID)
func threadNodesForOwner(_ ownerId: String, allNodes: [ThreadNode]) -> [ThreadNode]
```

Two operational details:

- `THREAD_HOST_OVERRIDE` rewrites a registering node's advertised host. This
  exists for deployments where the node reports an address Sewn cannot route to.
- Nodes not seen for **300 s** are treated as stale.

---

## Document Identity

`Sewn+Utilities.computeHash(from:)` derives a document CID from its text:
lowercase, split on whitespace, strip punctuation, drop a small stop-word set
(`the, and, a, an, in, on, at, for, of, to, is, it, that, this`), then hash the
remaining tokens. Two uploads of the same prose get the same id, which is what
makes re-indexing idempotent. Tested by `Flow1_DocumentCIDTests.swift`.

---

## Building a New Feature That Touches Sewn

1. **New write path** → add a `WriteJob` case and handle it in `execute`; never
   mutate through a second queue.
2. **New Thread operation** → add the proto message pair, then a `fanout*`
   method in `Sewn+ThreadFanout.swift`. Route handlers call `fanout*`, never a
   gRPC client directly.
3. **New billing field** → add to `Sewn.DocumentStats`, then the merge logic in
   `SewnRegistry.addPerformance`, then a `RegistryWALRecord` case, then the WAL
   replay. Missing the WAL step means the field silently resets on restart.
4. **New registry field** → remember the tolerant decoder: use
   `decodeIfPresent` with a default so old files still load.
5. **New route** → register it in `configureRoutes` **before** `Application.init`.
6. **Tests** → the `Flow*` files by area (see `Skills/TestMaintenance/README.md`).

---

## What Is No Longer Here

`PartitionTable`, `PartitionIndex`, `PartitionQuantizer`, `HNSWGraph`,
`HNSWVectorStore`, `HNSWTopologyWAL`, `TableMutator`, `PersonalHNSWMutator`, the
standalone `IndexQueue` actor, per-owner personal graphs, the Oracle P2P mesh,
and `Sewn+Migration.swift` — all removed. Vector and graph code lives in the
[Thread](https://github.com/riteshpakala/Totem) repository; see
`Skills/Thread/README.md`.
