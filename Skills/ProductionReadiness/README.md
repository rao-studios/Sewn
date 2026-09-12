# Production Readiness

Checklists, deployment procedure, and runbooks for Sewn in production.

---

## Pre-Deployment Checklist

### Build

- [ ] Two sibling packages are checked out beside this repo: **`Conduit`**
      (`../../../rao/repositories/Conduit`) and **`Frigate`** (`../Frigate`).
      Both are path dependencies — a missing checkout fails the build.
- [ ] `swift build -c release` succeeds
- [ ] `swift test` passes
- [ ] `swiftlint` clean (`.swiftlint.yml` at the root; SwiftLint is a package
      dependency)
- [ ] `Package.resolved` committed
- [ ] For on-device: `./scripts/build-metallib.sh release` has produced
      `mlx.metallib` beside the binary. **SwiftPM has no Metal step** — without
      this, the `local` provider 503s

### Environment

Every variable Sewn actually reads:

| Variable | Required | Purpose |
|----------|----------|---------|
| `SUPABASE_URL` | **Yes — `fatalError` if absent** | Auth |
| `SUPABASE_ANON_KEY` | **Yes — `fatalError` if absent** | Auth |
| `MISTRAL_API_KEY` | Effectively yes | Chat, and vision/embeddings/speech for *every* provider |
| `TINKER_API_KEY` | Only for `tinker` | 503 per request when absent |
| `SUPABASE_SERVICE_KEY` | For service-role calls | |
| `ADMIN_USER_ID` | For any admin route | Unset ⇒ every admin route 403s |
| `METRICS_TOKEN` | Recommended | Guards `GET /metrics` |
| `SEWN_GLOBAL_LLM` | No | `mistral` \| `tinker` \| `local`; unknown values fall back to mistral |
| `SEWN_DATA_DIR` | No | Storage root; `--data-dir` wins |
| `SEWN_CHAT_MODEL`, `TINKER_MODEL`, `SEWN_LOCAL_MODEL` | No | Per-provider chat model |
| `UTILITY_MODEL`, `SEWN_CODING_MODEL`, `SEWN_LOCAL_CODING_MODEL` | No | Job-specific models |
| `VISION_MODEL`, `SEWN_REALTIME_OPENING_MODEL` | No | |
| `SEWN_LOCAL_UTILITY` | No | `1` lets Sinatra/auto-memory/compaction run on-device |
| `THREAD_HOST_OVERRIDE` | No | Rewrites a registering node's advertised host |
| `SEWN_REGION` | No | Log/metric labeling |
| `COCKPIT_TOKEN`, `COCKPIT_METRICS_ENDPOINT`, `COCKPIT_LOGS_ENDPOINT` | For observability | Read by Alloy, not by Sewn |
| `AIRTABLE_API_KEY` | No | Only if the Airtable endpoint is used |

- [ ] `SUPABASE_URL` and `SUPABASE_ANON_KEY` are set. **These two `fatalError` at
      startup** — unlike LLM keys, which degrade to a 503
- [ ] `ADMIN_USER_ID` is the intended single account. It is **one id, not an
      allowlist**
- [ ] No secrets in source, `docker-compose.yml`, or the image

### Security

- [ ] Data directory not world-readable: `chmod 700 ~/Documents/sewn-db`
- [ ] `GET /metrics` gated by `METRICS_TOKEN` and/or the reverse proxy
- [ ] TLS terminates at the reverse proxy — Sewn serves plain HTTP, and the gRPC
      transport is **`.plaintext`**
- [ ] gRPC port 9091 reachable only from Thread nodes. It is an unauthenticated
      registration surface: anything that can reach it can register as a node
- [ ] `GET /v1/stats`, `/v1/threads`, `/health`, and the auth routes are **open**.
      `/v1/stats` has its own per-IP rate limiter; the others do not
- [ ] Wallet registry is an **unencrypted property list** — accept or mitigate

### Data & fleet

- [ ] `GET /v1/threads` shows every expected node with `is_active: true`
- [ ] At least one node reports `accepting_storage: true`, or indexing silently
      drops
- [ ] `registry-wal` is a sane size (checkpoint fires at 16 MB)
- [ ] No negative wallet balances
- [ ] A restart reloads registry, Sinatra, and wallet state

### Performance baseline

- [ ] `/health` < 5 ms p99
- [ ] `/v1/chat/completions` non-stream p95 within budget for your model
- [ ] `sewn.chat.ttft` acceptable — this is the number users feel
- [ ] `sewn.index.queue_depth` returns to 0 after ingestion
- [ ] Memory stable over a sustained hour

---

## Deployment

```bash
./start.sh        # docker compose down, rebuild, up -d, wait for /health
./stop.sh
```

`start.sh` polls `http://localhost:8080/health` for up to two minutes, then
prints status and the last 20 log lines. A timeout warning usually means Swift is
still compiling, not that the deploy failed.

### docker-compose

```yaml
services:
  sewn:
    ports:
      - "8080:8080"
      - "9091:9091"          # gRPC — Thread registration
    env_file: [.env]
    volumes:
      - sewn-volume-dev:/root/Documents/sewn-db
    restart: unless-stopped
  alloy:
    image: grafana/alloy:latest
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
volumes:
  sewn-volume-dev:
    external: true           # ← must be created by hand first
```

Three gotchas, all of which have bitten:

1. **The volume is `external: true`.** `docker volume create sewn-volume-dev`
   before the first `up`, or compose refuses to start.
2. **`docker-compose.yml` names `dockerfile: Dockerfile`, but the file on disk is
   lowercase `dockerfile`.** This works on macOS's case-insensitive filesystem
   and fails on a case-sensitive one. Rename or fix the reference before
   deploying to Linux.
3. **The container mounts `/root/Documents/sewn-db`**, matching the in-container
   default data root. Changing `--data-dir` without changing the mount silently
   writes to the container's ephemeral layer.

The image is a two-stage build on `swift:6.0.0-jammy`, running
`--host 0.0.0.0 --port 8080`. **The Linux image cannot serve the `local`
provider** — MLX is macOS-only.

### Flags

```bash
./sewn-server \
  --host 0.0.0.0 \
  --port 8080 \
  --data-dir ~/Documents/sewn-db \
  --grpc-port 9091 \
  --enable-threads \          # default true
  --vlm \                     # multi-modal chat input
  --enable-prompt-cache \
  --prompt-cache-size-mb 1024 \
  --prompt-cache-ttl-minutes 30
```

Models come from the **environment**, not from flags. There is no `--model`,
`--mistral`, `--embedding-model`, `--enable-oracle`, `--node-id`, or `--peers` —
all removed.

---

## Observability

Metrics at `GET /metrics` (Prometheus text, guarded by `METRICS_TOKEN`), scraped
by the Alloy sidecar and pushed to Scaleway Cockpit (Mimir + Loki + Grafana).

### Structured logs

`SewnLogger` emits JSON lines with a `service` field. Alloy's
`loki.process "label_service"` stage promotes it to a `service_name` Loki label,
which is what populates Cockpit's drilldown tabs (Sewn, Sinatra, Gita, GBT
Training, Parking, Embedding). `requestId`, `ownerId`, and `documentId` are
extracted too.

Non-JSON lines fall back to `service_name="sewn-server"`. (The Alloy config
comment still calls those "Vapor framework output" — stale wording; the framework
is Hummingbird.)

Conduit's session and client logs route through `SewnConduitLogger` so they land
in the same stream under `service: "Sewn"`. If session diagnostics are missing
from Cockpit, that bridge is the thing to check.

### Metrics worth alerting on

| Metric | Watch for |
|--------|-----------|
| `sewn.index.queue_depth` | Unbounded growth ⇒ ingestion outpacing Thread |
| `sewn.chat.ttft` | User-visible latency |
| `sewn.chat.search_duration`, `sewn.chat.compact_duration` | Compaction is the dominant pre-stream cost |
| `sewn.realtime.first_audio` | The number the two-pass design exists to lower |
| `sewn.realtime.tts_failures_total` | Turns that lost audio |
| `sewn.realtime.retrieval_failures_total` | Turns answered degraded |
| `sinatra.unadjusted_total{reason}` | All `no_model`/`no_collector` ⇒ training never runs |
| `sinatra.parked_records` | Pinned at 30 ⇒ the rolling cap is evicting |
| `provider.llm_requests_total{model}` | Confirms which model is actually serving |
| `provider.embedding_queue_depth` | Tasks waiting on an embedding slot |

Also present: `sewn.search.*`, `sewn.hnsw.*` and `sewn.pq.*` (fed from
Thread-reported stats, not a local graph), `sewn.batch.*`, `sinatra.*` training
gauges.

### Grafana dashboards

`Dashboards/*.json` — import via **Grafana → Dashboards → Import → Upload JSON**:
`sewn-overview`, `sewn-database`, `sewn-ml-inference`, `sewn-batch-pipeline`,
`sewn-downtime`, `sewn-ip-traffic`, `sewn-infrastructure`, `sewn-sinatra`.

---

## Runbooks

### Retrieval returns nothing

```bash
curl -s localhost:8080/v1/threads | jq
```

1. **No nodes** → nothing registered. Check port 9091 reachability from the node
   and the node's own mothership address.
2. **Nodes present, `is_active: false`** → heartbeats stopped. `isActive` is a
   **60-second** window on `lastSeen`; entries are purged at 300 s.
3. **A node advertises an unroutable host** → set `THREAD_HOST_OVERRIDE`.
4. **Nodes active, searches still empty** → `_threadQueryClient` may be nil
   (`--enable-threads false`), or the query is scoped to a group/owner with
   nothing in it.

Nothing in this path errors. Empty results are the only symptom.

### Indexing accepted but documents unsearchable

1. `accepting_storage` on at least one node? Indexing targets **one** node, and
   with none accepting it drops.
2. `sewn.index.queue_depth` — is the queue draining?
3. Logs for the backpressure warning: three retries at 500 ms / 1 s / 2 s, then
   the batch is dropped with a warning. **This is the silent data-loss path** —
   alert on it.
4. `/v1/embeddings` returns as soon as the job is enqueued, so a 200 means
   "accepted", not "stored".

### Provider failures

```bash
curl -s localhost:8080/v1/providers | jq '.providers[] | {id, available, state, reason}'
```

`reason` is written to be read. Missing key → set it. `localNotBuilt` → non-macOS
build or absent MLX. `failed` with a GPU remedy → `LocalGPU.remedy()` says what
to do. Warm the on-device model with `POST /v1/providers/local/warm`.

### Sinatra tone never changes

1. `sinatra.unadjusted_total{reason}`:
   - `no_model` / `no_collector` → the owner has never passed the training gate
   - `no_registry` → persistence problem
2. `POST /v1/frank/parking` — is anything parked? The gates are strict: user
   reply ≥ 4 words, resonance confidence ≥ 0.55, and the excerpt must be a
   verbatim substring.
3. `POST /v1/frank/gbt` — inspect trees for overfit.
4. `POST /v1/frank/export` before `POST /v1/frank/reset`, so a bad state can be
   analyzed after wiping it.

### Wallet or pricing looks wrong

1. Find the turn's three `service: .gita, flow: .chat` log lines: **Token
   Ledger**, **Cost Breakdown** (with surge), **Owner Payouts**.
2. Check the invariant: `owners.earning.sum + serviceCharge == totalCost`.
3. A new model missing from the `Gita.TokenLedger` catalog silently prices at
   `mistral-medium` rates. This is the most common cause.
4. Surge is 1.15× at load 1 of 10 by design, not a bug.

### Clean shutdown

`Sewn.shutdown()` calls `RegistryMutator.flushForShutdown()` — `saveNow` then
truncate the WAL. Skipping it is survivable (the WAL replays at startup) but
leaves work for boot.

### Restoring after data loss

There is **no `/v1/storage/*` backup or restore surface** — those routes were
removed. Back up by snapshotting the data directory or the Docker volume. Thread
nodes hold documents and vectors independently, so losing `sewn-db` loses
billing stats, Sinatra models, and the wallet — **not the corpus**.

---

## Audit Frequency

| Area | When |
|------|------|
| `GET /v1/threads` | Continuously, alerting |
| `sewn.index.queue_depth`, drop warnings | Continuously, alerting |
| Provider availability | On deploy and on key rotation |
| Wallet invariant | After any release touching Gita |
| Sinatra gates | Monthly, or on a tone complaint |
| WAL size | Weekly |
| Full pre-release checklist | Every production release |

---

## Known Operational Gaps

- **No backup/restore routes.** Volume snapshots only.
- **`/v1/admin/owner/delete` reports `documentsRemoved: 0`** — `removeAll`
  returns 0 now. `sinatraCleared` is accurate.
- **Admin list and audit routes are stubs.** `list/owners`, `list/documents`,
  `list/groups`, `audit/stale`, `audit/reconcile` return empty or zero.
- **gRPC registration is unauthenticated.** Network-level control only.
- **Wallet at rest is unencrypted.**
- **`sewn-volume-dev` is `external: true`** and must be created manually.
- **The `dockerfile` / `Dockerfile` casing mismatch** breaks case-sensitive
  filesystems.
