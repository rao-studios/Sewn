# System Architecture Reference

## Overview

Sewn is an AI assistant server written in Swift on **Hummingbird 2**. It is the
**reasoning layer** of MaryOS and the **orchestration layer** of a distributed
retrieval architecture: it owns authentication, chat completions, sentiment-tuned
generation, attribution and royalty accounting, and fan-out to **Thread** nodes.

The single most important architectural fact: **Sewn stores no vectors, no HNSW
graph, and no knowledge graph.** All document, vector, and graph data lives on
Thread nodes, which dial *in* to Sewn over gRPC. Sewn holds only what is its own —
ownership-free billing stats, learned Sinatra models, and the wallet ledger.

Everything is one Swift process. Heavy state lives in actors rather than an
external database; what must survive restart is persisted as property lists and a
write-ahead log under `~/Documents/sewn-db`.

---

## Component Map

```
HTTP Request                                 WebSocket upgrade
    │                                              │
    ▼                                              ▼
┌──────────────────────────────────┐   ┌────────────────────────────┐
│        Middleware Pipeline        │   │  wsRouter (separate tree)  │
│  IPMetricsMiddleware (all)        │   │  bearer checked in         │
│  AuthMiddleware (protected tree)  │   │  shouldUpgrade             │
│  AdminMiddleware (/v1/admin/*)    │   │  → /v1/realtime/chat       │
└──────────────────────────────────┘   └────────────────────────────┘
    │                                              │
    ▼                                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Route Handlers                           │
│                   (Sources/API/Routes/*.swift)                  │
│   Chat · Complete · Skills · Code · Search · Embeddings ·       │
│   Graph · Stats · Infinite · Frank · Wallet · Admin · …          │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────┐       ┌──────────────────────────────┐
│      Sewn (actor)        │◄─────►│       Sinatra (class)        │
│  orchestration hub       │ tone  │  per-owner GBT + IMBHS       │
│                          │       │  resonance · sentiment       │
│  WriteJob FIFO queue     │       │  technical indicators        │
│  RegistryMutator         │       └──────────────────────────────┘
│  DocumentCache           │
│  nodeId (stable UUID)    │       ┌──────────────────────────────┐
└──────────────────────────┘──────►│        Gita (class)          │
    │                     spans/   │  word-count royalty shares   │
    │                     pricing  │  [[n]] marker → char spans   │
    │                              │  token ledger · wallet       │
    │                              └──────────────────────────────┘
    │
    ├──────────────────────┬─────────────────────────┐
    ▼                      ▼                         ▼
┌──────────────┐  ┌──────────────────┐  ┌─────────────────────────┐
│ ModelProvider│  │  SewnGRPCServer  │  │   SupabaseProvider      │
│ mistral      │  │  :9091 Conduit   │  │   auth · profile        │
│ tinker       │  │  Thread registers │  └─────────────────────────┘
│ local (MLX)  │  │  + bidi session   │
└──────────────┘  └──────────────────┘
                           │
                           ▼
              ┌─────────────────────────────┐
              │   Thread nodes (external)   │
              │  documents · vectors ·      │
              │  HNSW · PQ · knowledge graph│
              └─────────────────────────────┘
```

`Sources/Core/Sewn+Marielle.swift` and `Sources/API/Routes/Marielle.swift` exist
but every Marielle route returns **503** — the implementation was written against
a local HNSW graph that no longer lives here. See `Skills/Marielle/README.md`.

---

## Core Actors (Concurrency Boundaries)

| Actor | File | Responsibility |
|-------|------|---------------|
| `Sewn` | `Sources/Core/Sewn.swift` | Orchestration hub. Owns the write queue, the registry mutator, the document cache, and the Thread query client |
| `RegistryMutator` | `Sources/Core/Mutators/RegistryMutator.swift` | Serializes `SewnRegistry` (billing stats) writes **and** holds the live Thread node registry |
| `PersistenceActor` | `Sources/Utilities/Persistence/PersistenceActor.swift` | One per logical file — all disk I/O for that file is serialized here |
| `SewnGRPCServer` | `Sources/Conduit/SewnGRPCServer.swift` | Hosts the Conduit registration service on `:9091` |
| `EmbeddingModelProvider` | `Sources/Providers/EmbeddingModelProvider.swift` | Bounded-concurrency embedding calls (Mistral) |
| `LocalInference` | `Sources/Providers/Local/LocalInference.swift` | On-device MLX generation, macOS only |
| `ExternalLogQueue` | `Sources/SewnLogger.swift` | Batches log shipping off the request path |
| `NetworkService` | `Sources/API/Network/NetworkService.swift` | One per hosted vendor endpoint |

There is **one** mutator actor, not four. `TableMutator`, `PersonalHNSWMutator`,
and the standalone `IndexQueue` actor are gone — they served a local vector store
that now lives on Thread.

### Why a single FIFO write queue inside the Sewn actor?

`Sewn` serializes every index mutation through one queue (`Sources/Core/Sewn.swift`):

```swift
private enum WriteJob {
    case put([Sewn.BatchPutItem], SewnRequest)
    case removeBatch([(documentId: String, ownerId: String)])
    case removeAll(ownerId: String, request: SewnRequest, CheckedContinuation<Int, Never>)
}
private var pending: [WriteJob] = []
private var isProcessing = false
```

Actor isolation protects `pending` and `isProcessing`. When `drain()` suspends
awaiting a fan-out, new `enqueue()` calls only *append* — `isProcessing` blocks a
second drain. That preserves the ordering guarantee that matters: **no
`removeBatch` can interleave mid-`putBatch`**.

Two behaviors worth knowing:

- **Put coalescing.** Consecutive `.put` jobs sharing the same `ownerId` and
  `group.id` are merged into one job, up to `maxCoalesceItems = 100`. A burst of
  single-document indexes becomes one fan-out.
- **`removeAll` is awaitable.** It carries a `CheckedContinuation`, so the purge
  handler can return an accurate count even while earlier jobs are still queued.
  `put` and `removeBatch` are fire-and-forget.

Queue depth is reported as `sewn.index.queue_depth`.

---

## Request Lifecycle: Chat Completion

The most composed path in the system. Sentiment and retrieval start **together**,
because neither depends on the other.

```
POST /v1/chat/completions
    │
    ├─ IPMetricsMiddleware → per-IP counters
    ├─ AuthMiddleware → validate Supabase JWT → context.authUserId
    │
    ├─ Resolve the turn's backend: request.provider ?? LLMProvider.serverDefault
    │
    ├─ Sewn.handleChat(request:modelProvider:sewnRequest:queryExpansion:)
    │   │
    │   ├─ [concurrent] Sinatra.prepare(messages, provider:)
    │   │     ├─ Extract the resonance passage (LLM)
    │   │     ├─ Score sentiment (structured LLM tool call)
    │   │     ├─ Train per-owner GBT + harmony memory
    │   │     └─ → PrepareResult { ledger, documentStatsUpdates, resonancePartition }
    │   │
    │   ├─ [concurrent] fanoutSearch(queryText:request:topK:)
    │   │     ├─ Broadcast to every ACTIVE Thread node
    │   │     ├─ Thread embeds locally, runs hybrid KG + PQ search
    │   │     └─ Merge results + union the graph trace
    │   │
    │   ├─ Gita.track(.inference) → word-count royalty shares (unpriced)
    │   ├─ compact(history + partitions) → briefing text
    │   ├─ Assemble persona + instructions + context + citation protocol
    │   │
    │   ├─ ModelProvider.run/stream(prompt, tuned parameters)
    │   │     └─ Completion contains invisible [[n]] markers
    │   │
    │   ├─ Gita.annotate(text, contribution)
    │   │     ├─ STRIP every marker (always, contribution or not)
    │   │     └─ Resolve markers → character spans per document
    │   ├─ Gita.priceContribution(tokenLedger) → LLM cost + service charge
    │   ├─ RegistryMutator.accumulateEarnings / accumulatePerformance
    │   └─ Sewn.enqueuePut(resonancePartition) when Sinatra found one
    │
    └─ Response — text, tone, references, contribution
       (stream: true sends the same content as SSE deltas)
```

Attribution lands in **two stages**, and the split is the point: retrieval knows
*which documents* were consulted and in what proportion, but only the generated
text reveals *which sentences actually used them*. Shares are computed during
search, refined into character spans after generation, and priced last — against
the turn's real token ledger, which by then includes the compaction, resonance,
and sentiment calls as well as the generation itself.

---

## Request Lifecycle: Document Indexing

Sewn prepares and routes; **Thread embeds and stores.**

```
POST /v1/embeddings
    │
    ├─ AuthMiddleware → ownerId
    │
    ├─ sanitize: true?  → TextChunker (1500 chars max; paragraph → sentence → hard split)
    ├─ Tags: client-supplied, else TagGenerator over the text
    ├─ Merge tags into group metadata
    │
    ├─ Sewn.enqueuePut(batchItems, request:)   ← returns immediately
    │   │
    │   └─ (when the FIFO drains to this job)
    │       └─ fanoutIndex(partitions:request:)
    │           ├─ request.threadIds set?  → that node, if active
    │           ├─ else                    → first node accepting storage
    │           ├─ Thread embeds, trains PQ, inserts HNSW, links KG entities
    │           ├─ Accepted     → RegistryMutator.recordOwnerThread(owner → node)
    │           └─ Backpressure → jittered backoff 500ms / 1s / 2s, then drop
    │
    └─ Route already responded; indexing continues in the background
```

Indexing is the one operation that is **not** broadcast. A document lives on a
single Thread node and Sewn remembers which one (`ownerThreadMap`); search
fan-out is what makes it findable again.

---

## Retrieval Strategy

Sewn does no embedding for retrieval and holds no index. `fanoutSearch` passes the
raw **query text**; each Thread embeds it locally and runs its own hybrid search
(entity match → graph expansion → HNSW → PQ re-rank). Sewn's job is the merge:

1. Broadcast the `ThreadSearchRequest` to every active node concurrently
   (`withTaskGroup`).
2. Collect partition results and union the graph traces (entity matches,
   expansion edges).
3. Sort by score, de-duplicate, truncate to `topK`.
4. A node that fails is logged and skipped — surviving nodes' partial results are
   still merged.

The `sewn.hnsw.*` and `sewn.pq.*` metric families still exist and are fed from
Thread-reported stats, not from any local graph.

---

## Storage Layout

Root: `~/Documents/sewn-db`, overridden by `--data-dir` (wins) or `SEWN_DATA_DIR`.
`FilePersistence` encodes **property lists**, not JSON.

```
~/Documents/sewn-db/
├── registry              # SewnRegistry — billing stats + bridging opt-ins ONLY
├── registry WAL          # append-only billing mutations, replayed at startup
├── wallet_registry       # Gita.WalletRegistry — earnings, cashout history
├── sinatra/registry      # per-owner GBT models, datasets, harmony memories, parked entries
├── documents/{id}        # document metadata envelopes
├── conversations/{id}    # conversation history
├── personalities         # chat persona list
└── node identity         # stable mothership UUID (NodeIdentity)
```

In a full MaryOS install these sit beside their siblings:

```
~/Documents/MaryOS/
├── sewn-db/      # this repository — registry, Sinatra models, wallet
├── thread-db/    # memory — graphs, vectors, documents
└── fleet-db/     # training — datasets, adapters
```

**What is NOT here:** no HNSW topology, no vector store, no PQ codebooks, no
partition table, no document ownership map. Thread owns all of it.

### SewnRegistry is billing-only

```swift
/// Lean billing-only registry. Document/group/ownership data lives on Thread nodes.
struct SewnRegistry: Codable {
    var documentStats: [DocumentID: Sewn.DocumentStats] = [:]
    var bridgingEnabledOwners: Set<OwnerID> = []
}
```

Its decoder is deliberately tolerant: `decodeIfPresent` on both fields, so a
registry serialized before Thread became the source of truth still decodes — the
large legacy fields (`ownersDocuments`, groups, access maps) are simply skipped.

`RegistryWAL` records only billing mutations for the same reason; the
`documentRegistered` / `ownerLinked` record types were removed. Checkpoint
threshold is **16 MB**.

---

## Access Control Model

Document and group access levels live on **Thread**, and Thread enforces scope on
every search. Sewn passes intent, not policy:

```
SewnRequest.scope       → "personal" | "global" (forwarded to Thread)
SewnRequest.aggregate   → merge across groups
SewnRequest.groups/group → restrict to these group ids
SewnRequest.threadIds   → pin the request to specific nodes
```

The one access fact Sewn still owns is Marielle bridging:
`SewnRegistry.bridgingEnabledOwners`, an explicit per-owner opt-in for
cross-owner question generation.

`AuthMiddleware` overwrites `sewn.owner_id` with the JWT-derived id on every
non-admin route, so a client cannot address another owner's data by editing the
body. Admin routes keep the supplied `owner_id` — that is the point of them.

---

## Middleware Stack

| Middleware | Applied To | What It Does |
|------------|------------|-------------|
| `IPMetricsMiddleware` | All routes | Per-IP Prometheus counters |
| `AuthMiddleware` | The `protected` route tree | Validates the Supabase bearer token, populates `context.authUserId`, overwrites `sewn.owner_id` |
| `AdminMiddleware` | The `admin` route tree | Gates `/v1/admin/*` on an admin-scoped token |
| `TokenValidator` | `/metrics`, WS upgrade | Shared token validation; results cached by token |

The WebSocket route is registered on a **separate router** with
`BasicWebSocketRequestContext`, so upgrade matching never scans routes that
cannot upgrade. Bearer auth for realtime happens in `shouldUpgrade`, before the
upgrade completes.

---

## Startup Sequence (`Sources/SewnServer.swift`)

1. `loadDotEnv()` — read `.env` into the environment.
2. Resolve the storage root — `--data-dir`, then `SEWN_DATA_DIR`, then `~/Documents/sewn-db`.
3. Bootstrap logging and the Prometheus metrics backend.
4. Construct the `Sewn` actor — loads node identity, registry, Sinatra and wallet state from disk.
5. Construct `ModelProvider` — one `NetworkService` per hosted vendor plus `LocalInference`.
6. Start `SewnGRPCServer` on `--grpc-port` (default **9091**) — Thread registration opens.
7. `configureRoutes(router, …)` — CORS, IP metrics, then the open / protected / admin trees.
8. `configureWebSocketRoutes(…)` — the separate WS router for `/v1/realtime/chat`.
9. `Application.init` — **freezes the responder**.
10. If the default provider is `local`, warm the on-device model so turn one doesn't pay for the load.
11. `runService` on `--port` (default 8080).

> **Every route must be registered before step 9.** `Application.init` freezes the
> responder; a route added afterwards is silently unreachable. This is the single
> easiest way to add an endpoint that returns 404 with no error anywhere.

### CLI flags

| Flag | Default | Notes |
|------|---------|-------|
| `--host` | `127.0.0.1` | |
| `--port` | `8080` | |
| `--data-dir` | `~/Documents/sewn-db` | Wins over `SEWN_DATA_DIR` |
| `--grpc-port` | `9091` | `docker-compose.yml` publishes 9091 to match |
| `--enable-threads` | `true` | Thread registration is on by default |
| `--vlm` | `false` | Multi-modal chat input |
| `--enable-prompt-cache` | `false` | With `--prompt-cache-size-mb` (1024), `--prompt-cache-ttl-minutes` (30) |

Models are chosen by **environment variable**, not by flag — see
`Skills/Providers/README.md`.

---

## Key Design Decisions & Rationale

### Why Hummingbird 2?
Swift-native, async/await throughout, and a router that composes middleware trees
cleanly (`router.add(middleware:)` returning a sub-router is how the open /
protected / admin split is expressed). It also shares the process with Frigate's
MLX stack for on-device inference. The trade is the frozen responder — routes are
not dynamic.

### Why actors instead of locks?
Compile-time data-race safety. The remaining wrinkle is that hot-path *reads*
shouldn't pay an actor hop, which is why snapshots are exposed `nonisolated` over
a `ReadWriteValue` (see `Skills/Caching/README.md`).

### Why does Thread dial in, rather than Sewn dialing out?
Inversion is deliberate. A Thread node can live behind NAT, on a laptop, or in
another region and still join the fan-out set the moment it starts. There is no
node list to configure and no discovery protocol — the set of nodes serving a
query is whatever holds an open session at that moment.

### Why is indexing routed to one node while search is broadcast?
A document's vectors and graph edges have to be co-located to be searchable, so a
document lives on exactly one node. Broadcasting search is what makes the fleet
look like one corpus. The cost is that Sewn must remember owner → node affinity,
which is what `ownerThreadMap` is for.

### Why word-count royalty shares?
It is the only proportion that can be computed *before* the model speaks, from
evidence that already exists (the retrieved text). Everything finer — which
sentence used which source — requires the generated text, which is why spans are
a second stage. Equal split among co-owners is the deliberate baseline; weighting
by document kind, retrieval count, or recency is marked as future work in
`Gita+Royalty.swift`.

### Why GBT for sentiment-driven tone?
Interpretable, fast at inference, and trainable per-user on 50–200 samples.
A neural approach could not be personalized per owner on commodity hardware, and
could not be inspected the way `POST /v1/frank/gbt` inspects a tree.

### Why does the registry only hold billing data?
Because two sources of truth for document ownership is a bug generator. When
Thread became authoritative for documents, groups, and access, the choice was to
delete those fields rather than mirror them. What is left is what Thread does not
know about: earnings, retrieval counts, sentiment sums, bridging opt-ins.

---

## Where Things Moved

| Was | Now |
|-----|-----|
| Vapor 4 | Hummingbird 2 |
| `Sources/Database/` | `Sources/Core/` |
| `TableMutator`, `PersonalHNSWMutator` | Deleted — vectors live on Thread |
| `IndexQueue` actor | `Sewn`'s internal `WriteJob` FIFO queue |
| `PartitionTable`, `PartitionQuantizer`, `HNSWGraph`, `HNSWVectorStore`, `HNSWTopologyWAL` | The Thread repository |
| Oracle / P2P mesh, trust scores, gossip | Deleted. Only the `OracleNodeID` typealias (`= UUID`) survives, as the key type for `Gita.Payload.peerSources` |
| `/v1/hnsw/*` routes | `POST /v1/graph` (knowledge-graph proxy) and `GET /v1/stats` |
| `/v1/storage/*` backup/restore routes | Removed |
| `/v1/batch/embeddings` | Removed — `/v1/embeddings` takes batches |
| `~/.sewn/` | `~/Documents/sewn-db` |
| Registry as ownership index | Registry as billing stats only |
