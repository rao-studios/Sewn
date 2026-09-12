# Sewn Skills

Maintenance, reference, and operational knowledge for every system in the Sewn
server. Use these when building features, auditing behavior, writing tests, or
deploying.

Sewn is the **reasoning layer** of MaryOS and the **orchestration layer** of a
distributed retrieval architecture. Two facts shape every document here:

1. **Sewn stores no vectors, no HNSW graph, and no knowledge graph.** Thread
   nodes hold all of it and dial *in* over gRPC. `SewnRegistry` holds billing
   stats and nothing else.
2. **Routes must be registered before `Application.init`.** Hummingbird freezes
   the responder; anything added later is silently unreachable.

---

## Directory Structure

```
Skills/
├── SystemReference/        — Architecture, routes, data models
│   ├── Architecture.md     — Component map, actors, lifecycles, storage, startup, rationale
│   ├── RouteReference.md   — Every endpoint: tree, auth, schema, business logic
│   └── DataModels.md       — Every persisted / wire / shared Swift type
│
├── Sewn/                   — The orchestration actor
│   └── README.md           — Write queue, search, compaction, auto-memory, billing accumulation
│
├── Thread/                 — Distributed retrieval integration
│   └── README.md           — Registration, session lifecycle, every fanout* primitive, where the vector code went
│
├── Conduit/                — The gRPC session layer (sibling package)
│   └── README.md           — SewnGRPCServer, HTTP/2 tuning, session manager, proto change process
│
├── Graph/                  — Thread proxy routes
│   └── README.md           — POST /v1/graph, GET /v1/stats, the sewn request object
│
├── Providers/              — Which backend answers
│   └── README.md           — mistral | tinker | local, resolution, ModelConfig, on-device MLX
│
├── Realtime/               — The two-pass voice turn
│   └── README.md           — WebSocket wire, turn engine, TTS lane, the seam, barge-in
│
├── Chat/                   — Chat completions and its four siblings
│   └── README.md           — The pipeline, parameter precedence, personalities, streaming
│
├── Sinatra/                — Sentiment, GBT, resonance
│   └── README.md           — The gated loop, structured sentiment, tone derivation, IMBHS
│
├── Gita/                   — Attribution, royalty, wallet
│   └── README.md           — Word-count shares, three span tiers, pricing, credits
│
├── Concurrency/            — What is serialized, and why
│   └── README.md           — The WriteJob FIFO queue, RegistryMutator, PersistenceActor, the WAL
│
├── Caching/                — Synchronization primitives
│   └── README.md           — ReadWriteValue, LockedValue, DocumentCache, SewnCache, FilePersistence
│
├── Marielle/               — Personalization (NOT implemented — all routes 503)
│   └── README.md           — What exists, what is missing, notes for whoever picks it up
│
├── FeatureAuditing/        — Per-system audit checklists
│   └── README.md           — Externally checkable: a route, a metric, or a log line
│
├── TestMaintenance/        — Test suite guide
│   └── README.md           — The Flow convention, fixtures, templates, coverage gaps
│
└── ProductionReadiness/    — Deployment & operations
    └── README.md           — Env vars, Docker, observability, runbooks, known gaps
```

---

## Quick Lookup

| I want to... | Go to |
|-------------|-------|
| Find a route's schema, tree, or auth | [SystemReference/RouteReference.md](SystemReference/RouteReference.md) |
| Understand how all systems connect | [SystemReference/Architecture.md](SystemReference/Architecture.md) |
| Look up a Swift type | [SystemReference/DataModels.md](SystemReference/DataModels.md) |
| Know why my search returns nothing | [Thread/README.md](Thread/README.md) — Debugging |
| Add a Thread operation | [Thread/README.md](Thread/README.md) + [Conduit/README.md](Conduit/README.md) |
| Change the proto | [Conduit/README.md](Conduit/README.md) — Changing the Protocol |
| Understand gRPC throughput or keepalive | [Conduit/README.md](Conduit/README.md) — HTTP/2 tuning |
| Add or debug a provider | [Providers/README.md](Providers/README.md) |
| Run a model on-device | [Providers/README.md](Providers/README.md) — The `local` Provider |
| Work on voice / realtime | [Realtime/README.md](Realtime/README.md) |
| Change the chat pipeline | [Chat/README.md](Chat/README.md) |
| Understand parameter precedence | [Chat/README.md](Chat/README.md) — Generation Parameter Precedence |
| Change how sentiment affects tone | [Sinatra/README.md](Sinatra/README.md) |
| Know why tone never changes | [Sinatra/README.md](Sinatra/README.md) — Inference, then `sinatra.unadjusted_total` |
| Change royalty or pricing | [Gita/README.md](Gita/README.md) |
| Understand `[[n]]` markers and spans | [Gita/README.md](Gita/README.md) — Stage 2 |
| Add an index or remove path | [Concurrency/README.md](Concurrency/README.md) — The WriteJob Queue |
| Add a persisted field | [Concurrency/README.md](Concurrency/README.md) + [Caching/README.md](Caching/README.md) |
| Choose a synchronization primitive | [Caching/README.md](Caching/README.md) — Decision Guide |
| Query the knowledge graph | [Graph/README.md](Graph/README.md) |
| Implement Marielle | [Marielle/README.md](Marielle/README.md) — What Is Missing |
| Audit a system before a release | [FeatureAuditing/README.md](FeatureAuditing/README.md) |
| Write a test | [TestMaintenance/README.md](TestMaintenance/README.md) |
| Deploy, or run a runbook | [ProductionReadiness/README.md](ProductionReadiness/README.md) |
| Find where deleted code went | [SystemReference/Architecture.md](SystemReference/Architecture.md) — Where Things Moved |

---

## System Map (one line each)

| System | What it does |
|--------|-------------|
| **Sewn** | The orchestration actor: composes a turn, owns the write queue and the Thread client |
| **Thread** (external) | Documents, vectors, HNSW, PQ, knowledge graph. Dials in over gRPC; receives all fan-out |
| **Conduit** (external) | The gRPC wire: `thread.proto`, session manager, query client, node record |
| **Providers** | `mistral` \| `tinker` \| `local`. Per-request selection; honest 503s |
| **Realtime** | Two-pass voice turn over WebSocket: instant opening, grounded continuation |
| **Chat** | The composed turn — retrieval, tone, persona, attribution, pricing |
| **Sinatra** | Per-owner GBT + IMBHS. Resonance-gated learning that tunes the next turn |
| **Gita** | Word-count royalty shares, `[[n]]` → character spans, token-ledger pricing, wallet |
| **Concurrency** | One FIFO write queue, one mutator actor, one `PersistenceActor` per file |
| **Caching** | `ReadWriteValue`, `LockedValue`, `DocumentCache`, `SewnCache`, `FilePersistence` |
| **Graph** | `POST /v1/graph` knowledge-graph proxy, `GET /v1/stats` public counts |
| **Marielle** | Personalization. **Not implemented** — all four routes 503 |
| **Auth** | Supabase JWT via `AuthMiddleware`; `AdminMiddleware` gates on a single `ADMIN_USER_ID` |
| **Admin** | Cross-owner ops. `modify`, `sinatra/gbt`, `model`, `personalities`, `owner/delete` work; list and audit routes are stubs |

---

## Gone, and Where to Look Instead

| Was | Now |
|-----|-----|
| Vapor 4 | Hummingbird 2 |
| `Sources/Database/` | `Sources/Core/` |
| `TableMutator`, `PersonalHNSWMutator`, `IndexQueue` actor | One `WriteJob` FIFO queue inside the `Sewn` actor → [Concurrency](Concurrency/README.md) |
| `PartitionTable`, `PartitionQuantizer`, `HNSWGraph`, `HNSWVectorStore`, `HNSWTopologyWAL` | The Thread repository → [Thread](Thread/README.md) |
| Oracle / P2P mesh, trust scores, gossip | Deleted. Only `typealias OracleNodeID = UUID` survives → [Gita](Gita/README.md) |
| `Skills/HNSW/`, `Skills/PartitionTable/` | Folded into [Thread](Thread/README.md) and [Graph](Graph/README.md) |
| `/v1/hnsw/*`, `/v1/admin/hnsw/*`, `/v1/admin/table/document` | `POST /v1/graph`, `GET /v1/stats` → [Graph](Graph/README.md) |
| `/v1/storage/*` backup & restore | Removed. Snapshot the volume → [ProductionReadiness](ProductionReadiness/README.md) |
| `/v1/batch/embeddings` | `/v1/embeddings` takes batches |
| `/v1/models` | `GET /v1/providers` → [Providers](Providers/README.md) |
| `/v1/completions` | `/v1/complete`, narrowed → [Chat](Chat/README.md) |
| `~/.sewn/` | `~/Documents/sewn-db` |
| Registry as ownership index | Billing stats only |

---

## Adding a New Skill

When a new system is built:

```
Skills/NewSystem/
└── README.md   — what it does, how it works, the decisions and their reasons,
                  integration points, known gaps
```

Then update this file's directory structure, quick lookup table, and system map.

Two conventions worth keeping: **document the reason, not just the mechanism** —
the constants and guards in this codebase mostly encode a past incident — and
**say plainly when something is unimplemented or stubbed**, as `Marielle` and the
admin list routes do.
