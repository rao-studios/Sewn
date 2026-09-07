# Production Readiness

Checklists, deployment procedures, and operational guidance for Sewn in production.

---

## Pre-Deployment Checklist

### Code & Build

- [ ] `swift build -c release` succeeds with no warnings
- [ ] All tests pass: `swift test` (no failures, no skips without explanation)
- [ ] SwiftLint passes: `swiftlint` (zero errors, zero warnings)
- [ ] No `// TODO` or `// FIXME` comments that are release-blockers
- [ ] Package.swift dependencies are pinned (`Package.resolved` committed)

### Security

- [ ] `MISTRAL_API_KEY` is in environment, NOT in source or docker-compose
- [ ] Supabase anon/service keys are in environment, NOT in source
- [ ] `~/.sewn/` data directory is NOT world-readable: `chmod 700 ~/.sewn`
- [ ] Admin owner_id allowlist is configured correctly (not empty, not wildcard)
- [ ] `GET /metrics` is not publicly accessible (firewall or reverse proxy gate)
- [ ] TLS is terminated at the reverse proxy (Sewn itself runs HTTP internally)

### Data Integrity

- [ ] Run `POST /v1/admin/audit/stale` — zero stale documents
- [ ] HNSW WAL file is reasonable size (< 100MB pre-compaction)
- [ ] Wallet registry has no negative balances
- [ ] Gita registry market weights sum ≈ 1.0 per owner

### Performance Baseline

- [ ] `/health` responds in < 5ms (p99)
- [ ] `POST /v1/chat/completions` (non-stream) responds in < 2s (p95) for 512 max_tokens
- [ ] `POST /v1/embeddings` responds in < 200ms (p95)
- [ ] `POST /v1/search` responds in < 100ms (p95) with 10k+ documents in HNSW
- [ ] Memory usage stable under sustained load (no leak over 1 hour run)

### Oracle (if enabling)

- [ ] `--node-id` is set to a stable UUID (not regenerated on restart)
- [ ] Seed peers are reachable from the deployment host
- [ ] WebSocket port is open in firewall rules
- [ ] Gossip doesn't cause runaway message amplification (test with 3+ nodes)

---

## Docker Deployment

```bash
# Build
docker build -t sewn-server:latest .

# Run with environment
docker run -d \
  --name sewn \
  -p 8080:8080 \
  -v ~/.sewn:/root/.sewn \
  -e MISTRAL_API_KEY=sk-... \
  -e MLX_ENV=production \
  sewn-server:latest \
  --model /models/mistral-7b \
  --host 0.0.0.0 \
  --port 8080

# Check health
curl http://localhost:8080/health

# Tail logs
docker logs -f sewn
```

### docker-compose (development)

```bash
docker-compose up -d
docker-compose logs -f
docker-compose down
```

---

## Startup Arguments Reference

```bash
./sewn-server \
  --model <path>                    # Required: path to MLX model OR model name for Mistral
  --host 0.0.0.0                    # Default: localhost (change for external access)
  --port 8080                        # Default: 8080
  --mistral                          # Use Mistral API instead of local MLX
  --vlm                              # Enable visual language model (experimental)
  --embedding-model <path>           # Optional: separate embedding model
  --enable-prompt-cache              # Enable KV cache
  --prompt-cache-size-mb 1024        # Cache RAM limit (default 1GB)
  --prompt-cache-ttl-minutes 30      # Cache TTL (default 30min)
  --enable-oracle                    # Enable P2P mesh
  --node-id <stable-uuid>            # Stable Oracle node identity
  --peers "wss://a:8080,wss://b:8080" # Seed Oracle peers
```

---

## Operational Runbooks

### Runbook: Nightly HNSW Compaction

**When**: Daily, low-traffic window (e.g. 3am)
**Why**: Removes tombstoned nodes, reduces WAL size, speeds up search

```bash
curl -X POST https://your-server/v1/admin/hnsw/compact \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

Expected response: `{ "compacted_nodes": N, "elapsed_ms": N }`

Monitor: verify HNSW node count drops by any deleted documents since last compaction.

### Runbook: Weekly Audit & Reconcile

**When**: Weekly
**Why**: Catch stale registry entries from partial failures

```bash
# Step 1: Identify stale documents
curl -X POST https://your-server/v1/admin/audit/stale \
  -H "Authorization: Bearer $ADMIN_TOKEN"

# Step 2: If stale_documents is non-empty, reconcile
curl -X POST https://your-server/v1/admin/audit/reconcile \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"document_ids": [...]}'
```

### Runbook: Sinatra Reset for Misbehaving Owner

**When**: A specific user reports wildly wrong tone (very cold responses in emotional conversations)
**Why**: GBT model may have overfit on unusual data

```bash
curl -X POST https://your-server/v1/frank/reset \
  -H "Authorization: Bearer $USER_TOKEN" \
  -d '{"owner_id": "uuid"}'
```

Sinatra will retrain from scratch over the next few inferences.

### Runbook: Emergency Owner Data Delete

**When**: User requests full data deletion (GDPR/privacy)
**Why**: Complete erasure of all associated data

```bash
curl -X POST https://your-server/v1/admin/owner/delete \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"owner_id": "uuid"}'
```

Verify: check `GET /v1/admin/list/owners` — owner should no longer appear.

### Runbook: Oracle Peer Recovery

**When**: A peer node goes offline and comes back
**Steps**:
1. Peer reconnects via WebSocket (automatic if `--peers` is in startup args)
2. Check `GET /oracle/nodes` — peer state should transition to `connected`
3. If not reconnecting: POST new peer endpoint to `/oracle/peers`
4. Trust score will resume from pre-disconnect value (persists across reconnects)

### Runbook: Backup Before Migration

**When**: Before any major schema change or infrastructure move

```bash
# For each owner
for OWNER_ID in $(curl -X POST /v1/admin/list/owners -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.owners[]'); do
  curl -X POST https://your-server/v1/storage/backup \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"owner_id\": \"$OWNER_ID\"}"
done
```

---

## Performance Tuning

### HNSW Parameters

| Scenario | `M` | `efSearch` | Tradeoff |
|----------|-----|-----------|---------|
| Fast search, lower recall | 8 | 20 | Faster, slightly less accurate |
| Default | 16 | 50 | Balanced |
| High recall | 32 | 100 | Slower insertion and search, higher accuracy |
| Very large graph (500k+ nodes) | 16 | 200 | More traversal per query for better recall at scale |

### Prompt Cache

- Enable for production workloads where users have repeat conversations
- Disable if memory is constrained (cache consumes up to `--prompt-cache-size-mb`)
- TTL of 30 minutes suits most conversational patterns

### GBT Training Frequency

- Default park threshold (50 samples per owner) is conservative
- For high-volume users: lower threshold to 20 (faster adaptation, more CPU)
- For low-volume users: raise to 100 (fewer retrains, coarser model)

---

## Monitoring

### Key Prometheus Metrics to Watch

| Metric | Alert If |
|--------|---------|
| `sewn_inference_count_total` | Drops to 0 (server stopped processing) |
| `sewn_hnsw_node_count` | Decreases unexpectedly without delete operations |
| `sewn_index_queue_depth` | Stays > 100 for > 5 minutes (indexing backlog) |
| `sewn_sinatra_park_queue_depth` | > 500 per owner (GBT training not keeping up) |
| `http_request_duration_seconds` p99 | > 5s for chat completions |
| `sewn_oracle_peer_failures_total` | Rapid increase (peer connectivity issue) |

### Log Levels

Sewn uses `SewnLogger`. In production:
- Set `MLX_ENV=production` → info-level logging only
- Set `MLX_ENV=development` → debug-level (verbose, not for production)

---

## Security Hardening

- [ ] Reverse proxy (nginx/caddy) with TLS in front of Sewn (Sewn serves HTTP)
- [ ] Rate limiting at reverse proxy (e.g. 60 req/min per IP for /v1/chat/completions)
- [ ] `GET /metrics` blocked externally (internal-only scrape from Prometheus)
- [ ] `~/.sewn/` data encrypted at rest (disk-level or application-level)
  - **Note**: Application-level encryption is a TODO in `Storage.swift`
- [ ] Supabase RLS (Row Level Security) policies reviewed for any Supabase tables used by backup/restore
- [ ] Admin owner_id is a service account, not a user-facing account
- [ ] Logs do not contain full JWT tokens (check `SewnLogger` redaction)

---

## Disaster Recovery

### Scenario: Server crash, WAL intact

1. Restart server normally — WAL replays automatically
2. Verify node count: `POST /v1/admin/system/stats`
3. Run `POST /v1/admin/audit/stale` to catch any partial-write orphans

### Scenario: Corrupt HNSW graph

1. Stop server
2. Delete `~/.sewn/global_graph` and `~/.sewn/personal_graphs/`
3. Run `POST /v1/storage/restore` for each owner to re-index from Supabase backup
4. Alternatively: rebuild from scratch via batch embeddings if backup is unavailable

### Scenario: Corrupt Sinatra registry

1. Stop server
2. Delete `~/.sewn/sinatra/registry`
3. Restart — Sinatra initializes fresh (no GBT models, will retrain from next inferences)
4. No data loss — GBT models are learned, not user data

### Scenario: Corrupt Gita wallet

1. This is high-stakes — do NOT delete without audit
2. Export current wallet data: `GET /v1/admin/list/owners` + `GET /v1/wallet` per owner
3. Reconstruct from `credit_exchanges` records (CreditExchange → Transaction history)
4. Wallet balance = sum of all royalty transactions - cashouts
