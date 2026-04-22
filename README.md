# Seer

A personalized AI assistant server built in Swift on [Vapor](https://vapor.codes), originally based on [swift-mlx-server](https://github.com/mzbac/swift-mlx-server). Seer provides a Mistral-compatible LLM and embedding API while layering in sentiment-aware personalization, document ownership tracking, and a P2P-ready embedding network. There is plans to support MLX in the future just for Apple Silicon based server hosting.

Seer hopes to answer an important question: *"When does generative AI qualify for fair use?"*

---

## Overview

Seer is designed around four core services:

- **Seer** — Vector document database with KNN search, access control, and partition-based storage. Users contribute documents as embeddings that grow a shared, permissioned knowledge network. Global-scope queries use an HNSW-PQ index for sublinear search; personal/group queries run per-document PQ linear scan.
- **Self-RLHF** — A Gradient Boosted Trees (GBT) sentiment analysis layer that dynamically adjusts generation parameters (temperature, top-p, repetition penalty) based on conversation tone. Also collects RLHF training data via user reactions.
- **Gita** — A royalty tracking system that calculates contribution percentages for each document owner whose data influenced an inference.
- **Oracle** — An optional P2P mesh layer for distributed search across multiple Seer nodes. Enabled at startup with `--enable-oracle`. Nodes discover each other via WebSocket and forward search queries to peers.

Seer also has a sister application that is soon to be released on iOS.

---

## Authentication — Powered by Supabase

Seer uses [supabase-swift](https://github.com/supabase/supabase-swift), the open-source Swift SDK from the [Supabase](https://supabase.com) project, as its authentication backend.

All protected routes require a `Bearer` token issued by Supabase. The `AuthMiddleware` validates each token via `auth.user(jwt:)` and injects the resolved `userId` into every downstream handler, binding documents, groups, and royalty contributions to their owners.

**Auth endpoints** (public, no token required):

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/auth/sign-up` | Register a new user |
| `POST` | `/v1/auth/sign-in` | Sign in with email + password |
| `POST` | `/v1/auth/verify` | Verify OTP (signup / recovery / magic link) |
| `POST` | `/v1/auth/refresh` | Refresh an access token |
| `POST` | `/v1/auth/reset-password` | Send a password recovery email |
| `POST` | `/v1/auth/sign-out` | Invalidate the current session (requires Bearer) |

See [docs/Auth-iOS.md](docs/Auth-iOS.md) for full iOS integration examples, Swift models, and cURL quick-reference.

---

## API Endpoints

All endpoints below require `Authorization: Bearer <access_token>`.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | None | Health check |
| `GET` | `/metrics` | None | Prometheus metrics (scraped by Grafana Alloy) |
| `GET` | `/v1/models` | None | List available models |
| `GET` | `/v1/oracle/nodes` | None | List known Oracle peer nodes and local node ID |
| `POST` | `/v1/chat/completions` | Bearer | Chat completions with sentiment-aware personalization |
| `POST` | `/v1/embeddings` | Bearer | Generate embeddings and store documents |
| `POST` | `/v1/batch/embeddings` | Bearer | Batch embedding generation |
| `POST` | `/v1/search` | Bearer | Semantic search with royalty tracking |
| `POST` | `/v1/modify` | Bearer | Update document access level or group membership |
| `POST` | `/v1/modify/group` | Bearer | Update group access state and sync all documents in the group |
| `POST` | `/v1/tools/summarize` | Bearer | Summarize text |
| `POST` | `/v1/list/documents` | Bearer | List documents for the authenticated user |
| `POST` | `/v1/list/groups` | Bearer | List groups for the authenticated user |
| `POST` | `/v1/storage/backup` | Bearer | Upload all document envelopes to Supabase Storage |
| `POST` | `/v1/storage/manifest` | Bearer | Return server-side document manifest for the authenticated user |
| `POST` | `/v1/storage/restore` | Bearer | Download all stored document envelopes from Supabase Storage |
| `POST` | `/v1/storage/purge` | Bearer | Remove all documents from Supabase Storage and the server-side index for the authenticated user |
| `POST` | `/v1/storage/purge/documents` | Bearer | Remove specific documents and clean up empty groups |
| `POST` | `/v1/oracle/peers` | Bearer | Connect this node to a new Oracle peer |
| `WS` | `/speak` | Bearer | WebSocket text-to-speech (Mistral Voxtral) |

---

## Configuration

Create a `.env` file in the project root:

```env
SUPABASE_URL=https://<your-supabase-project>.supabase.co
SUPABASE_ANON_KEY=<your-anon-key>

# Scaleway Cockpit — see Observability section below
COCKPIT_TOKEN=<token-from-cockpit-console>
COCKPIT_METRICS_ENDPOINT=https://<project-id>.metrics.cockpit.fr-par.scw.cloud/api/v1/push
COCKPIT_LOGS_ENDPOINT=https://<project-id>.logs.cockpit.fr-par.scw.cloud/loki/api/v1/push
METRICS_TOKEN=<random-secret>   # guards GET /metrics from public access
```

---

## Running the Server

```bash
./start.sh
```

The build script accepts flags to configure the model and runtime:

| Flag / Option | Description |
|---------------|-------------|
| `--host` | Bind address (default: `127.0.0.1`) |
| `--port` | Port (default: `8080`) |
| `--model` | Path to MLX model directory |
| `--embedding-model` | Path or identifier for the embedding model |
| `--mistral` | Enable Mistral API over custom models |
| `--vlm` | Enable vision language model support |
| `--enable-prompt-cache` | Enable KV-cache reuse for common prompt prefixes |
| `--prompt-cache-size-mb` | Max prompt cache size in MB (default: 1024) |
| `--prompt-cache-ttl-minutes` | Prompt cache TTL in minutes (default: 30) |
| `--enable-oracle` | Enable the Oracle P2P mesh for distributed search |
| `--node-id` | Stable UUID for this Oracle node (auto-generated if omitted) |
| `--peers` | Comma-separated seed peer URLs to connect at startup |

Example:

```bash
swift run seer-server --host 0.0.0.0 --port 8080

# With Oracle P2P enabled
swift run seer-server --host 0.0.0.0 --port 8080 \
  --enable-oracle \
  --node-id "550e8400-e29b-41d4-a716-446655440000" \
  --peers "http://192.168.1.2:8080,http://192.168.1.3:8080"
```

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
    │
    ├─ SelfRLHF.prepare()          Sentiment analysis via GBT
    ├─ Seer.search()              KNN vector retrieval
    │     ├─ global scope         HNSW-PQ index (sublinear)
    │     └─ personal/group       Per-document PQ linear scan
    ├─ Oracle.searchWithPeers()   Distributed search across P2P mesh (optional)
    ├─ Context engineering        Compact messages + retrieved context
    ├─ Tone adjustment            SelfRLHF tunes generation params
    └─ ModelProvider.run()        Mistral / local MLX inference
    │
    ▼
Gita.inference()                 Royalty contribution calculation
    │
    ▼
ChatCompletionResponse (with tone, references, contribution)
```

**Atlas** (`POST /v1/atlas`) exposes the global HNSW graph — node embeddings and neighbor
assignments — for 3-D visualisation. See [docs/Atlas.md](docs/Atlas.md).

### Oracle — Distributed P2P Search

Oracle is an optional mesh layer that lets multiple Seer nodes collaborate on search.
Enabled with `--enable-oracle` at startup. Nodes connect via WebSocket, exchange embeddings,
and merge result sets. See [docs/Oracle.md](docs/Oracle.md).

---

## Observability

Seer ships a full observability stack built on [Scaleway Cockpit](https://www.scaleway.com/en/docs/observability/cockpit/) (managed LGTM — Loki, Grafana, Mimir). The server pushes metrics and logs via a [Grafana Alloy](https://grafana.com/docs/alloy/latest/) sidecar; no scraping endpoint is exposed to the public internet.

### Architecture

```
┌──────────────────────────────────────┐
│  Docker Compose (Scaleway Instance)  │
│                                      │
│  ┌─────────────┐   ┌───────────────┐ │
│  │ seer-server │──▶│ Grafana Alloy │ │
│  │(Vapor/Swift)│   │  (sidecar)    │ │
│  └─────────────┘   └──────┬────────┘ │
│                           │ push     │
└───────────────────────────┼──────────┘
                            ▼
               ┌────────────────────────┐
               │    Scaleway Cockpit    │
               │  Mimir · Loki · Grafana│
               └────────────────────────┘
```

- **Alloy** collects Docker container logs (stdout/stderr) and host-level metrics (CPU, memory, disk, network) with zero application changes.
- **swift-prometheus** (`PrometheusMetricsFactory`) is bootstrapped at startup; Vapor's built-in `swift-metrics` instrumentation flows through it automatically.
- **Structured JSON logs** are emitted to stdout by `SeerLogger.externallyLog` for `warning` and above (and any call marked `externalOnly: true`). Alloy's pipeline stages index `level` and `service` as Loki stream labels.

### Structured Logs (Loki)

`SeerLogger` writes a JSON line to stdout for every log event at `warning` level and above, and for any `debug`/`info` call made with `externalOnly: true`. Alloy forwards these to Loki where they are queryable by `level` and `service`:

```logql
# All errors from the Seer database layer
{service="Seer"} | level="error"

# Trace a specific request across services
{service=~".+"} | json | requestId="<uuid>"
```

### Environment Variables

Add to `.env` (endpoints are found in Scaleway Console → Observability → Cockpit → Endpoints):

```env
COCKPIT_TOKEN=<token-from-cockpit-console>
COCKPIT_METRICS_ENDPOINT=https://<project-id>.metrics.cockpit.fr-par.scw.cloud/api/v1/push
COCKPIT_LOGS_ENDPOINT=https://<project-id>.logs.cockpit.fr-par.scw.cloud/loki/api/v1/push
METRICS_TOKEN=<random-secret>
```

`METRICS_TOKEN` is required in production. If set, `GET /metrics` returns `401` for any request that does not supply `Authorization: Bearer <token>`. Grafana Alloy reads the same variable and sends it automatically on every scrape.

### Grafana Dashboards

Four pre-built dashboards are in [`Dashboards/`](Dashboards/). Import each via **Grafana → Dashboards → Import → Upload JSON**, then map the `DS_PROMETHEUS` input to your Cockpit Mimir datasource.

| File | UID | Contents |
|------|-----|----------|
| [`seer-overview.json`](Dashboards/seer-overview.json) | `seer-overview` | Search rate, P50/P95/P99 latency, indexed documents, HNSW nodes, path distribution, index ops |
| [`seer-database.json`](Dashboards/seer-database.json) | `seer-database` | HNSW traversal cost (hops, layer-0 explored, candidates), latency percentiles, graph growth, search path % |
| [`seer-infrastructure.json`](Dashboards/seer-infrastructure.json) | `seer-infra` | CPU, memory, disk I/O, network throughput — host metrics from Alloy |

---

## Requirements

- Swift 5.10+
- Linux (Ubuntu Debian 24+) / macOS 14+
- A running Supabase project (self-hosted or cloud)
- Mistral-compatible LLM endpoint

---

## Dependencies

| Package | Purpose |
|---------|---------|
| [Vapor](https://github.com/vapor/vapor) | HTTP server framework |
| [supabase-swift](https://github.com/supabase/supabase-swift) | Authentication |
| [swift-crypto](https://github.com/apple/swift-crypto) | Cryptographic operations |
| [Web3.swift](https://github.com/Boilertalk/Web3.swift) | Ethereum / smart contract interaction |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing |
| [swift-prometheus](https://github.com/swift-server/swift-prometheus) | Prometheus metrics backend for swift-metrics |

---

## References & Notes

**Self-RLHF** implements [Improved Music Based Harmony Search Algorithm for Optimal Network Reconfiguration.](https://www.researchgate.net/publication/261109581_Improved_Music_Based_Harmony_Search_algorithm_for_Optimal_Network_Reconfiguration)

Claude Code (Sonnet) assisted from: [f73894e21fc8365970a184307acde0b6562826d9](https://github.com/riteshpakala/Seer/commit/f73894e21fc8365970a184307acde0b6562826d9)
- Monitoring the productivity impact of A.I. after the foundational architecture is made without A.I. Treating A.I. as a "scaler" in the development cycle.

## Get in touch

- https://paka.la

> *“The ability to observe without evaluating is the highest form of intelligence.” - J. Krishnamurti*