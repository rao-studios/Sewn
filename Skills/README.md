# Sewn Skills

Maintenance, reference, and operational knowledge for every system in the Sewn server. Use these when building new features, auditing existing behavior, writing tests, or preparing for deployment.

---

## Directory Structure

```
Skills/
├── SystemReference/          — Architecture, routes, data models
│   ├── Architecture.md       — Component map, request lifecycle, design decisions
│   ├── RouteReference.md     — Every endpoint: method, auth, schema, business logic
│   └── DataModels.md         — All Swift types across Sewn, Sinatra, Gita
│
├── Sewn/                     — Orchestration layer internals
│   └── README.md             — Fan-out, registry, search flow, auth, RAG pipeline
│
├── Thread/                    — Distributed vector search integration
│   └── README.md             — Registration, session stream, fan-out primitives, gRPC services
│
├── HNSW/                     — HNSW proxy routes (graphs live on Thread nodes)
│   └── README.md             — Route list, routing helpers, how to add HNSW features
│
├── PartitionTable/           — Moved to Thread
│   └── README.md             — Migration note, what was here, current Sewn fan-out API
│
├── Concurrency/              — Actor design, mutators
│   └── README.md             — RegistryMutator, actor design
│
├── Caching/                  — Synchronization primitives and caching layer
│   └── README.md             — SewnCache, DocumentCache, ReadWriteValue, LockedValue, PersistenceActor
│
├── Sinatra/                  — Sentiment & GBT system
│   └── README.md             — GBT model, IMBHS, technical indicators, tone adjustment
│
├── Gita/                     — Royalty & wallet system
│   └── README.md             — Market metaphor, royalty math, wallet, peer settlement
│
├── Marielle/                 — Personalization layer (not yet implemented)
│   └── README.md             — What needs to be done, prompt design
│
├── Chat/                     — Chat completions
│   └── README.md             — End-to-end chat flow, streaming, RAG injection, tone
│
├── FeatureAuditing/          — Audit checklists per system
│   └── README.md             — Per-system checklists, cross-cutting concerns
│
├── TestMaintenance/          — Test writing guide
│   └── README.md             — Flow convention, templates, gap analysis
│
└── ProductionReadiness/      — Deployment & operations
    └── README.md             — Deployment checklist, runbooks, monitoring, DR
```

---

## Quick Lookup

| I want to... | Go to |
|-------------|-------|
| Find a route's request/response schema | [SystemReference/RouteReference.md](SystemReference/RouteReference.md) |
| Understand how all systems connect | [SystemReference/Architecture.md](SystemReference/Architecture.md) |
| Look up a Swift type | [SystemReference/DataModels.md](SystemReference/DataModels.md) |
| Understand the Thread integration (gRPC, fan-out, session) | [Thread/README.md](Thread/README.md) |
| Understand HNSW proxy routes | [HNSW/README.md](HNSW/README.md) |
| Understand where PartitionTable/PQ went | [PartitionTable/README.md](PartitionTable/README.md) |
| Understand actor design and write serialization | [Concurrency/README.md](Concurrency/README.md) |
| Choose between ReadWriteValue, LockedValue, SewnCache | [Caching/README.md](Caching/README.md) |
| Change how sentiment affects tone | [Sinatra/README.md](Sinatra/README.md) |
| Change royalty calculation logic | [Gita/README.md](Gita/README.md) |
| Implement a Marielle personalization feature | [Marielle/README.md](Marielle/README.md) — see "What Needs to Be Done" |
| Understand the chat completion flow | [Chat/README.md](Chat/README.md) |
| Audit a system before a release | [FeatureAuditing/README.md](FeatureAuditing/README.md) |
| Write a test for a new feature | [TestMaintenance/README.md](TestMaintenance/README.md) |
| Deploy to production | [ProductionReadiness/README.md](ProductionReadiness/README.md) |
| Run operational runbooks | [ProductionReadiness/README.md](ProductionReadiness/README.md) — Runbooks section |

---

## System Map (one line each)

| System | What it does |
|--------|-------------|
| **Sewn** | Orchestration: auth, RAG search, chat, document lifecycle, Thread fan-out |
| **Thread** | External vector search nodes: HNSW + PQ storage, gRPC session, fan-out target |
| **HNSW** | Proxy routes to Thread: graph, stats, node inspection via gRPC |
| **PartitionTable** | Moved to Thread — PQ codebooks, PartitionIndex, TableMutator |
| **Concurrency** | Actor layer: RegistryMutator, write serialization |
| **Caching** | Sync primitives: SewnCache, DocumentCache, ReadWriteValue, LockedValue, PersistenceActor |
| **Sinatra** | Per-user GBT + IMBHS sentiment model that adjusts LLM temperature/top_p |
| **Gita** | Royalty ledger: documents earn credits when they contribute to inferences |
| **Marielle** | Personalization (not yet implemented): context-aware questions from user's HNSW graph |
| **Chat** | LLM inference pipeline: RAG retrieval + Sinatra tone + streaming SSE |
| **Auth** | Supabase JWT validation, admin gating |
| **Admin** | Privileged ops: owner delete, sinatra/gbt, table/document inspection; most others stubbed |
| **Storage** | Supabase backup/restore for user documents |

---

## Adding New Skills

When a new system is built, add a skill directory for it:

```
Skills/NewSystem/
└── README.md   — what it does, architecture, algorithms, integration points, TODOs
```

Update this file's directory structure and quick lookup table.
