# Seer

A personalized AI assistant server built in Swift on [Vapor](https://vapor.codes). Seer is the **orchestration layer** of a distributed vector search architecture: it handles authentication, chat completions (with RAG and Sinatra sentiment tuning), royalty tracking (Gita), and fan-out to **Totem** nodes — independently deployed vector search nodes that hold all document and HNSW data. Seer coordinates it; Totem stores and searches it.

Seer hopes to answer an important question: *"When does generative AI qualify for fair use?"*

---

## Core Services

| Service | Description |
|---------|-------------|
| **Seer** | Orchestration layer: auth, RAG search, chat completions, document lifecycle, Totem fan-out. |
| **Sinatra** | Gradient Boosted Trees (GBT) sentiment analysis that dynamically adjusts generation parameters (temperature, top-p, repetition penalty) based on conversation tone. Also collects RLHF training data via user reactions. |
| **Gita** | Royalty tracking system that calculates contribution percentages for each document owner whose data influenced an inference. |
| **Totem** (external) | Distributed vector search nodes. Each Totem registers with Seer over gRPC, holds a persistent bidirectional session stream, and receives all search/index/remove/library fan-out through that session. HNSW graphs and PQ codebooks live on Totem nodes. |

Seer has a sister iOS app, — [Open Source (Coming Soon)](https://github.com/riteshpakala/Sis).

---

## Architecture

```
Client Request
    │
    ▼
AuthMiddleware  ←─── Supabase (JWT validation)
    │
    ▼
Route Handler
    ├── Sinatra.prepare()         Sentiment analysis via GBT
    ├── fanoutSearch()    ──────► Totem nodes (gRPC) ──► HNSW-PQ KNN search
    ├── fanoutIndex()     ──────► Totem nodes (gRPC) ──► PQ train + HNSW insert
    ├── fanoutRemove()    ──────► Totem nodes (gRPC) ──► soft-delete + WAL
    ├── Context engineering       Compact messages + retrieved context
    ├── Tone adjustment           Sinatra tunes generation params
    └── ModelProvider.run()       Mistral / local MLX inference
    │
    ▼
Gita.inference()                 Royalty contribution calculation
    │
    ▼
ChatCompletionResponse (with tone, references, contribution)


Totem Registration (gRPC — port 9091):
    MothershipRegistrationService
        1. register()            — Totem sends host, grpcPort, httpPort, totemId
        2. session()             — bidirectional stream; Totem pings every 30 s;
                                   Seer sends fan-out payloads; Totem replies
        3. updateAvailability()  — Totem signals whether it accepts new document storage

GET /v1/totems                   — lists all registered Totem nodes (id, host, ports, status)
```

---

## Authentication

Powered by [Supabase](https://supabase.com) via [supabase-swift](https://github.com/supabase/supabase-swift). All protected routes require `Authorization: Bearer <access_token>`. The `AuthMiddleware` validates each token and injects the resolved `userId` into every downstream handler.

### Endpoints (no auth required)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/auth/sign-up` | Register a new user |
| `POST` | `/v1/auth/sign-in` | Sign in with email + password |
| `POST` | `/v1/auth/verify` | Verify OTP (signup / recovery / magic link) |
| `POST` | `/v1/auth/refresh` | Refresh an access token |
| `POST` | `/v1/auth/reset-password` | Send a password recovery email |
| `POST` | `/v1/auth/sign-out` | Invalidate the current session (requires Bearer) |

**`POST /v1/auth/sign-in`**
```json
// Request
{ "email": "user@example.com", "password": "secret" }

// Response
{ "accessToken": "...", "refreshToken": "...", "expiresIn": 3600, "userId": "uuid" }
```

See [docs/Auth-iOS.md](docs/Auth-iOS.md) for full iOS integration examples.

---

## API Reference

All endpoints below require `Authorization: Bearer <access_token>` unless noted.

### System

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | None | Health check |
| `GET` | `/metrics` | Token | Prometheus metrics |
| `GET` | `/v1/models` | None | List available models |
| `GET` | `/v1/totems` | None | List registered Totem nodes |

**`GET /v1/totems`**
```json
// Response
{
  "mothership_id": "uuid",
  "enabled": true,
  "nodes": [
    {
      "totem_id": "uuid",
      "host": "192.168.1.2",
      "grpc_port": 9090,
      "http_port": 8080,
      "last_seen": "2026-05-24T10:00:00Z",
      "is_active": true,
      "accepting_storage": true
    }
  ]
}
```

---

### Embeddings & Indexing

Fan-out to all active Totem nodes via gRPC session. Totem performs embedding, PQ training, and HNSW insertion.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/embeddings` | Embed text and index a single document |
| `POST` | `/v1/batch/embeddings` | Batch embed and index multiple documents |

**`POST /v1/batch/embeddings`**
```json
// Request
{
  "inputs": [{ "values": ["chunk a", "chunk b"] }, { "values": ["chunk c"] }],
  "model": "mistral-embed",
  "sanitize": false,
  "seer": { "owner_id": "uuid" }
}
// 3-phase: parallel sanitization → concurrent embedding → Totem index fan-out
```

---

### Search

Fan-out to all active Totem nodes via gRPC. Results are merged, re-ranked, and deduped by Seer.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/search` | Semantic KNN search over the user's document library |

**`POST /v1/search`**
```json
// Request
{
  "query": "what did I write about distributed systems?",
  "model": "mistral-embed",
  "seer": { "owner_id": "uuid" }
}

// Response
{
  "texts": ["retrieved context chunk..."],
  "references": ["document-id-1"],
  "contribution": { "document-id-1": 0.87 }
}
```

---

### Chat Completions

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/chat/completions` | Chat with Sinatra-tuned parameters and RAG context |

**`POST /v1/chat/completions`**
```json
// Request
{
  "messages": [{ "role": "user", "content": "Summarize my notes on HNSW." }],
  "model": "mistral-medium",
  "stream": false,
  "seer": { "owner_id": "uuid" }
}

// Response (stream: false)
{
  "choices": [{ "message": { "role": "assistant", "content": "..." }, "finishReason": "stop" }],
  "usage": { "prompt_tokens": 120, "total_tokens": 350 }
}
// stream: true → Server-Sent Events with delta chunks
```

Supports multi-modal input (images, video) when `--vlm` is enabled.

---

### Documents & Groups

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/list/documents` | List all documents owned by the authenticated user |
| `POST` | `/v1/list/groups` | List all groups owned by the authenticated user |
| `POST` | `/v1/modify` | Update a document's access level, group, or delete it |
| `POST` | `/v1/modify/group` | Update a group's access state and label |
| `POST` | `/v1/modify/group/remove` | Delete a group and all its documents |

**`POST /v1/modify`**
```json
// Request
{
  "update": { "operation": "remove", "documentId": "did" },
  "seer": { "owner_id": "uuid" }
}
// operation: "access" | "remove" | "group"
// "remove" fans out to Totem nodes; "access" and "group" update Seer registry
```

---

### Storage & Backup

Supabase Storage bucket (`documents`) with path `{userId}/{groupId}/{documentId}`. RLS enforces per-user isolation.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/storage/backup` | Upload all document envelopes to Supabase Storage |
| `POST` | `/v1/storage/manifest` | Return server-side document manifest |
| `POST` | `/v1/storage/restore` | Download all stored document envelopes |
| `POST` | `/v1/storage/purge` | Remove all documents from storage and server index |
| `POST` | `/v1/storage/purge/documents` | Remove specific documents |
| `POST` | `/v1/storage/purge/groups` | Remove specific groups and their documents |

---

### HNSW Graph

HNSW is managed entirely by Totem nodes. Seer acts as a thin gRPC proxy. Graph routes require `seer.totem_ids[0]` to specify the target Totem node. Stats routes fan out to **all** active Totem nodes and aggregate.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/hnsw/stats` | Aggregate stats across all active Totem nodes |
| `POST` | `/v1/hnsw/document/stats` | Stats filtered to one document across all nodes |
| `POST` | `/v1/hnsw/personal/stats` | Stats for a specific Totem node (requires `totem_ids`) |
| `POST` | `/v1/hnsw/personal` | Personal graph from a specific Totem node |
| `POST` | `/v1/hnsw/personal/hubs` | Hub-only personal graph (nodes with level > 0) |
| `POST` | `/v1/hnsw/personal/document` | Personal graph filtered to one document |
| `POST` | `/v1/hnsw/personal/documents` | Personal graph filtered to a set of document IDs |
| `POST` | `/v1/hnsw/global` | Global graph from a specific Totem node |
| `POST` | `/v1/hnsw/global/hubs` | Hub-only global graph |
| `POST` | `/v1/hnsw/documents` | Global graph filtered to a set of document IDs |
| `POST` | `/v1/hnsw/documents/hubs` | Hub-only global graph for a document set |
| `POST` | `/v1/hnsw/node` | Full single-node inspection (all layers + neighbors) |
| `POST` | `/v1/hnsw/nodes/batch` | Batch fetch multiple nodes by partition ID |
| `DELETE` | `/v1/hnsw/node` | Soft-delete a node on a specific Totem node |

```json
// Most graph routes require totem_ids to route to a specific node:
{ "seer": { "owner_id": "uuid", "totem_ids": ["totem-node-uuid"] } }
```

---

### Marielle — Personalization

> **Status: Not yet implemented.** All routes return `503 Service Unavailable`. Marielle requires Totem-hosted HNSW graphs to be accessible for personalized question generation.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/marielle/open` | Personalized opening question for a new session |
| `POST` | `/v1/marielle/proactive` | Check if Marielle has something to say |
| `POST` | `/v1/marielle/interject` | Mid-session lateral question |
| `POST` | `/v1/marielle/bridge` | Question bridging two profiles |

---

### Tools

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/tools/summarize` | LLM-based text summarization |
| `POST` | `/v1/speak` | Text-to-speech (PCM stream) |

---

### Profile & Feedback

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/profile?userId=<id>` | Get a user's profile |
| `PATCH` | `/v1/profile` | Update display name |
| `POST` | `/v1/feedback` | Submit user feedback |

---

### Wallet

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/wallet` | Earnings summary, cashout history, and group-level breakdown |

---

### Sinatra Debug (Frank)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/frank/gbt` | Full GBT model state (trees, hyperparameters, feature names) |
| `POST` | `/v1/frank/parking` | Real-time Sinatra pipeline snapshot |
| `POST` | `/v1/frank/reset` | Wipe all Sinatra state for the authenticated user |

---

### Admin

All admin routes require an admin-scoped Bearer token. `owner_id` in the body targets any user (not replaced by caller's ID).

| Method | Path | Status | Description |
|--------|------|--------|-------------|
| `POST` | `/v1/admin/list/owners` | Stub (returns `[]`) | List all registered owners |
| `POST` | `/v1/admin/list/documents` | Stub (returns `[]`) | List documents for any target owner |
| `POST` | `/v1/admin/list/groups` | Stub (returns `[]`) | List groups for any target owner |
| `POST` | `/v1/admin/modify` | Partial — `remove` works | Modify any document |
| `POST` | `/v1/admin/modify/group` | Partial | Modify any group |
| `POST` | `/v1/admin/hnsw/stats` | **503** — managed by Totem | HNSW stats |
| `POST` | `/v1/admin/hnsw/personal` | **503** — managed by Totem | Personal HNSW graph |
| `DELETE` | `/v1/admin/hnsw/node` | **503** — managed by Totem | Delete any HNSW node |
| `POST` | `/v1/admin/hnsw/compact` | **503** — managed by Totem | Compact graphs |
| `POST` | `/v1/admin/sinatra/gbt` | **Implemented** | Sinatra GBT state for any owner |
| `POST` | `/v1/admin/table/document` | **Implemented** | Document inspection via Totem fanout |
| `POST` | `/v1/admin/system/stats` | Stub (returns zeroes) | Aggregate system-wide statistics |
| `POST` | `/v1/admin/owner/delete` | **Implemented** | Atomic owner purge (docs + Sinatra) |
| `POST` | `/v1/admin/audit/stale` | Stub (returns `[]`) | Scan for orphaned registry entries |
| `POST` | `/v1/admin/audit/reconcile` | Stub (returns zeroes) | Remove stale documents |

**`POST /v1/admin/table/document`** fans out to Totem to fetch HNSW nodes for a document:
```json
// Request
{ "documentId": "did", "seer": { "owner_id": "uuid" } }

// Response — PQ stats are empty placeholders; HNSW data comes from Totem fanout
{
  "document_id": "did",
  "in_table_keys": true,
  "has_index": true,
  "partition_count": 4,
  "hnsw_node_count": 4,
  "hnsw_deleted_count": 0,
  "diverged": false,
  "tags": [],
  "pq": { "is_trained": false, ... },
  "partitions": [{ "partition_id": "...", "text": "...", ... }]
}
```

---

## Common Request Shape

All protected routes accept a `seer` object:

```json
{
  "seer": {
    "owner_id": "uuid",
    "group": { "id": "gid", "label": "Group Name" },
    "aggregate": true,
    "scope": "personal",
    "totem_ids": ["totem-uuid"],
    "request_id": "uuid"
  }
}
```

`AuthMiddleware` replaces `owner_id` with the authenticated user's JWT-derived ID for all non-admin routes. `totem_ids` is used by HNSW graph routes to pin a request to a specific Totem node.

---

## Configuration

Create a `.env` file in the project root:

```env
SUPABASE_URL=https://<your-supabase-project>.supabase.co
SUPABASE_ANON_KEY=<your-anon-key>

# Observability (Scaleway Cockpit)
COCKPIT_TOKEN=<token-from-cockpit-console>
COCKPIT_METRICS_ENDPOINT=https://<project-id>.metrics.cockpit.fr-par.scw.cloud/api/v1/push
COCKPIT_LOGS_ENDPOINT=https://<project-id>.logs.cockpit.fr-par.scw.cloud/loki/api/v1/push
METRICS_TOKEN=<random-secret>   # guards GET /metrics; Alloy sends it automatically
```

---

## Running the Server

```bash
./start.sh
```

| Flag | Description |
|------|-------------|
| `--host` | Bind address (default: `127.0.0.1`) |
| `--port` | HTTP port (default: `8080`) |
| `--model` | Path to MLX model directory |
| `--embedding-model` | Path or identifier for the embedding model |
| `--mistral` | Enable Mistral API over custom models |
| `--vlm` | Enable vision language model support |
| `--enable-prompt-cache` | Enable KV-cache reuse for common prompt prefixes |
| `--prompt-cache-size-mb` | Max prompt cache size in MB (default: 1024) |
| `--prompt-cache-ttl-minutes` | Prompt cache TTL in minutes (default: 30) |

Seer listens on port **9091** (gRPC) for Totem node registration. This is configured in `docker-compose.yml` and is not a CLI flag — it is always active.

```bash
# Standard
swift run seer-server --host 0.0.0.0 --port 8080
```

---

## Observability

Seer ships a full observability stack on [Scaleway Cockpit](https://www.scaleway.com/en/docs/observability/cockpit/) (Loki, Grafana, Mimir). A [Grafana Alloy](https://grafana.com/docs/alloy/latest/) sidecar pushes metrics and logs.

### Application Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `seer.search.total` | Counter | Total search requests |
| `seer.search.duration` | Histogram | Search latency (excludes embedding time) |
| `sinatra.inferences_total` | Counter | Total Sinatra GBT inference calls |
| `sinatra.adjustments_total` | Counter | Inferences where an adjustment was applied |
| `provider.llm_requests_total{model}` | Counter | LLM API requests dispatched |
| `provider.llm_request_duration` | Histogram | LLM API round-trip time (ms) |
| `provider.embedding_requests_total` | Counter | Embedding API requests dispatched |
| `provider.embedding_request_duration` | Histogram | Embedding API round-trip time (ms) |
| `provider.embedding_queue_depth` | Gauge | Tasks waiting for an embedding concurrency slot |

Metrics are at `GET /metrics`, scraped by Alloy every 30 seconds.

### Grafana Dashboards

Four pre-built dashboards in [`Dashboards/`](Dashboards/). Import via **Grafana → Dashboards → Import → Upload JSON**.

| File | UID | Contents |
|------|-----|----------|
| [`seer-overview.json`](Dashboards/seer-overview.json) | `seer-overview` | Search rate, latency percentiles, indexed documents |
| [`seer-database.json`](Dashboards/seer-database.json) | `seer-database` | HNSW traversal cost (via Totem nodes) |
| [`seer-infrastructure.json`](Dashboards/seer-infrastructure.json) | `seer-infra` | CPU, memory, disk I/O, network throughput |
| [`seer-ml-inference.json`](Dashboards/seer-ml-inference.json) | `seer-ml` | Search hit rate, LLM inference, embedding latency |

---

## Requirements

- Swift 5.10+
- Linux (Ubuntu/Debian 24+) or macOS 14+
- A running Supabase project (self-hosted or cloud)
- Mistral-compatible LLM endpoint
- One or more running [Totem](https://github.com/riteshpakala/Totem) nodes

## Dependencies

| Package | Purpose |
|---------|---------|
| [Vapor](https://github.com/vapor/vapor) | HTTP server framework |
| [supabase-swift](https://github.com/supabase/supabase-swift) | Authentication & storage |
| [swift-crypto](https://github.com/apple/swift-crypto) | Cryptographic operations |
| [Web3.swift](https://github.com/Boilertalk/Web3.swift) | Ethereum / smart contract interaction |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing |
| [swift-prometheus](https://github.com/swift-server/swift-prometheus) | Prometheus metrics backend |
| [grpc-swift](https://github.com/grpc/grpc-swift) | gRPC client/server for Totem integration |

---

## References

**Sinatra** implements [Improved Music Based Harmony Search Algorithm for Optimal Network Reconfiguration](https://www.researchgate.net/publication/261109581_Improved_Music_Based_Harmony_Search_algorithm_for_Optimal_Network_Reconfiguration).

## Development Patterns

Claude Code (Sonnet) assisted from: [f73894e](https://github.com/riteshpakala/Seer/commit/f73894e21fc8365970a184307acde0b6562826d9) — monitoring the productivity impact of AI after the foundational architecture was built without it. Treating AI as a "scaler" in the development cycle.

Claude Code (Sonnet) focuses on tests, observability, & enhancements from: 
    [d85023d](https://github.com/riteshpakala/Seer/commit/d85023db31a03c8d142195d15180c2d918824dcc) - New features are built manually.

---

## Get in touch

- https://paka.la

> *“The ability to observe without evaluating is the highest form of intelligence.” - J. Krishnamurti*