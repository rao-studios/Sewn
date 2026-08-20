# System Architecture Reference

## Overview

Seer is a local-first AI assistant server written in Swift using the Vapor 4 web framework. It combines a custom vector database, sentiment-aware LLM parameter tuning, a royalty ledger, and an optional P2P mesh into a single process. All heavy state (graphs, registries, ledgers) lives in Swift actors — no external database process.

---

## Component Map

```
HTTP Request
    │
    ▼
┌─────────────────────────────────────────────┐
│              Middleware Pipeline             │
│  AuthMiddleware → AdminMiddleware (admin)    │
│  IPMetricsMiddleware (all routes)            │
└─────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────┐
│                Route Handlers               │
│  (Sources/API/Routes/*.swift)               │
│  Chat, Search, Embeddings, HNSW, Admin, ... │
└─────────────────────────────────────────────┘
    │
    ├──────────────────────────────────────────┐
    │                                          │
    ▼                                          ▼
┌──────────────┐                    ┌──────────────────┐
│    SEER      │                    │    SINATRA       │
│  (Database   │◄──────────────────►│  (GBT Sentiment) │
│   Actor)     │  sentiment weights │                  │
│              │                    │  IMBHS (Harmony  │
│  HNSW Graphs │                    │  Memory)         │
│  PQ Indices  │                    │  GBT Model       │
│  Registry    │                    │  TechnicalIndic. │
└──────────────┘                    └──────────────────┘
    │                                          │
    ▼                                          ▼
┌──────────────┐                    ┌──────────────────┐
│    GITA      │                    │    ORACLE        │
│  (Royalty    │                    │  (P2P Mesh,      │
│   Ledger)    │                    │   optional)      │
│              │                    │                  │
│  Wallet      │                    │  DAG Topology    │
│  Credit Exch.│                    │  Trust Scores    │
│  Market Reg. │                    │  Gossip          │
└──────────────┘                    └──────────────────┘
    │
    ▼
┌──────────────┐
│   MARIELLE   │
│  (Context    │
│   Questions) │
└──────────────┘
```

---

## Core Actors (Concurrency Boundaries)

| Actor | File | Responsibility |
|-------|------|---------------|
| `Seer` | `Database/Seer.swift` | Database coordinator — coordinates all HNSW, PQ, registry ops |
| `TableMutator` | `Database/TableMutator.swift` | Serializes mutations to global HNSW graph (add/delete nodes) |
| `RegistryMutator` | `Database/RegistryMutator.swift` | Serializes metadata updates (document/group ownership) |
| `PersonalHNSWMutator` | `Database/PersonalHNSWMutator.swift` | Serializes per-owner personal graph mutations |
| `PersistenceActor` | `Utilities/PersistenceActor.swift` | Async disk I/O — all JSON file reads/writes route through here |
| `Sinatra` | `Sinatra/Sinatra.swift` | GBT model training and inference per owner |
| `Oracle` | `Database/Oracle/Oracle.swift` | P2P mesh coordinator — DAG, gossip, query fan-out |
| `IndexQueue` | `Utilities/IndexQueue.swift` | FIFO write serializer (workaround for actor reentrancy in HNSW mutation) |

### Why multiple mutator actors?

HNSW graph mutations are not reentrant-safe (they walk the graph while adding/removing nodes). The actor model serializes these safely, but because `Seer` itself also needs to await results from mutations, direct recursion would deadlock. The separate `TableMutator`, `RegistryMutator`, and `PersonalHNSWMutator` actors break the call chain.

---

## Request Lifecycle: Chat Completion

The most complex path — shows how all systems compose:

```
POST /v1/chat/completions
    │
    ├─ AuthMiddleware: validate Supabase JWT → extract owner_id
    │
    ├─ ChatCompletions handler
    │   ├─ Embed the last user message (EmbeddingModelProvider)
    │   ├─ Seer.search() → HNSW traversal → PQ rerank → top-K partitions
    │   │   └─ If Oracle enabled: also fan out to peers (Seer+Peer.swift)
    │   ├─ Sinatra.infer() → GBT scores sentiment → returns Tone
    │   │   └─ Tone adjusts: temperature, top_p, repetition_penalty
    │   ├─ Build system prompt with retrieved partitions
    │   ├─ ModelProvider.generate() → LLM call (Mistral or MLX)
    │   │   └─ Streaming: SSE chunked response
    │   │   └─ Non-streaming: JSON response
    │   ├─ Sinatra.park() → queue partitions for background GBT training
    │   └─ Gita.track() → record inference, calculate royalty distribution
    │
    └─ Response → client
```

---

## Request Lifecycle: Document Indexing

```
POST /v1/embeddings
    │
    ├─ AuthMiddleware → owner_id
    │
    ├─ Embeddings handler
    │   ├─ EmbeddingModelProvider.embed(text) → float32 vector
    │   ├─ Seer.put(document, partition) 
    │   │   ├─ RegistryMutator: add document/partition ownership
    │   │   ├─ TableMutator: insert node into global HNSW
    │   │   ├─ PersonalHNSWMutator: insert node into owner's personal graph
    │   │   └─ PartitionTable: store compressed embedding (PQ)
    │   ├─ Gita.track(payload: .put) → record document entry in market registry
    │   └─ Return DocumentResponse
    │
    └─ Response → client
```

---

## Hybrid Search Strategy

Two indices serve different access patterns:

| Index | Algorithm | When Used | Complexity |
|-------|-----------|-----------|------------|
| Global HNSW | Graph traversal (hierarchical layers) | Global/public search | O(log N) |
| Per-owner HNSW (personal) | Graph traversal | Personalized recency-weighted search | O(log N) |
| PartitionTable (PQ) | Product Quantization linear scan | Per-document fine rerank | O(K) where K = partitions |

**Flow**: HNSW finds approximate top-M candidates → PQ reranks for precision → top-K returned.

**Adaptive threshold**: Cosine similarity threshold starts static, then drifts based on training data distribution. Controlled by `PartitionQuantizer`.

---

## Storage Layout

```
~/.seer/
├── documents/{documentId}              # Document JSON metadata
├── conversations/{documentId}          # Conversation history JSON
├── sinatra/registry                    # Sinatra actor state (GBT models, datasets, harmony memories)
├── wallet_registry                     # Wallet ledger JSON
├── gita/registry                       # Gita economic registry JSON
├── personal_graphs/{owner_id}          # Per-owner HNSW graph (mmap binary)
├── global_graph                        # Global HNSW graph (mmap binary)
├── global_shard                        # Global PQ codebook + vector store
├── partition_table                     # Partition index (document → partitions mapping)
└── node_identity                       # This node's stable UUID (Oracle identity)
```

**Persistence mechanisms:**
- `FilePersistence` — JSON encode/decode to filesystem, coordinated through `PersistenceActor`
- `HNSWVectorStore` — mmap'd `float32` arrays (zero-copy read, direct memory write)
- `HNSWTopologyWAL` — append-only write-ahead log for HNSW graph structure changes
- Sinatra/Gita state: serialized JSON through `PersistenceActor`

---

## Access Control Model

```
SeerRegistry.Access:
  .available   → all owners can search
  .restricted  → only document owner can search
  .unknown     → not in registry (treat as restricted)

Bridging:
  bridging_enabled_owners → Set<Owner>
  When enabled: owner's documents surface to other users' personalized queries
```

Groups layer access on top:
- A group can be `.available` or `.restricted`
- Group access does NOT override document-level access (both must permit)

---

## Middleware Stack

| Middleware | Applied To | What It Does |
|------------|------------|-------------|
| `AuthMiddleware` | All protected routes | Validates Supabase JWT, injects `owner_id` into request storage |
| `AdminMiddleware` | `/v1/admin/*` | Checks `owner_id` against admin allowlist (config-driven) |
| `IPMetricsMiddleware` | All routes | Increments Prometheus counters by IP |

Auth token flow: `Authorization: Bearer <supabase_jwt>` → `SupabaseProvider.verify()` → `request.storage[OwnerKey]` = owner_id string.

---

## Startup Sequence (SeerServer.swift)

1. Parse CLI arguments (model path, host, port, oracle flags, peers)
2. Configure Vapor application (routes, middleware)
3. Initialize `Seer` actor (loads persisted graphs from disk)
4. Initialize `Sinatra` actor (loads GBT models from disk)
5. Initialize `Gita` actor (loads wallet registry from disk)
6. If `--enable-oracle`: initialize `Oracle`, connect to seed peers via WebSocket
7. Register all route handlers (30+ route files)
8. Start HTTP server

---

## Key Design Decisions & Rationale

### Why actors instead of locks?
Swift's actor model gives compile-time data race safety. The mutator pattern (separate actors for each write domain) avoids reentrancy deadlocks while keeping the main `Seer` actor as a coordination hub.

### Why HNSW + PQ hybrid?
HNSW is optimal for global approximate nearest neighbor search (O(log N)). For per-document reranking with small partition counts (5–50), a PQ linear scan beats graph traversal overhead. The two-stage pipeline gets both speed and accuracy.

### Why GBT for sentiment-driven tone?
Gradient boosted trees are interpretable, fast at inference, and trainable on small datasets (per-user). Neural approaches would require much more data and can't be personalized per-user on commodity hardware.

### Why the market metaphor in Gita?
Makes the royalty math intuitive: documents are "securities," each inference is a "trade" that distributes "dividends" to contributing owners. The metaphor also naturally accommodates future P2P settlement.

### Why Vapor?
Swift-native, high-performance, async/await native. Fits the same process as MLX-Swift local inference.

---

## P2P Oracle Integration Points

Oracle is currently wired to:
- `Seer+Peer.swift` — search fan-out during `Seer.search()`
- `OracleNodes.swift` — topology routes
- `SeerServer.swift` — startup flag + seed peer connection

**Not yet wired:**
- Chat completions stream from peer results (peer results join local results but aren't streamed independently)
- Gita royalty settlement across nodes (credit exchange is local-only)
- Trust score updates from semantic feedback (trust currently decays/grows on response receipt only)

See `Skills/Oracle/P2P-Wiring-Guide.md` for the planned integration map.
