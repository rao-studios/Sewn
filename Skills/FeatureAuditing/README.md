# Feature Auditing

Checklists and procedures for auditing every major feature in Sewn. Run these when: landing a large PR, after a refactor, before a release, or when a system has been dormant for a while.

---

## System-by-System Audit Checklists

### Sewn Database

- [ ] HNSW global graph: node count matches sum of all owner document partition counts
- [ ] HNSW personal graphs: every owner with documents has a personal graph
- [ ] Registry consistency: every document_id in `owners_documents` has a corresponding `document_owners` entry
- [ ] Registry consistency: every group in `owners_groups` has a corresponding `group_owners` entry
- [ ] PQ partition table: every partition in `PartitionTable` has a valid parent `document_id` in registry
- [ ] No orphaned HNSW nodes (nodes with no registry entry) — run `POST /v1/admin/audit/stale`
- [ ] Access control: `.available` documents are searchable cross-owner, `.restricted` are not
- [ ] `IndexQueue` is draining (not backed up) — check metrics for `index_queue_depth`
- [ ] WAL file size is reasonable (< 100MB before next compaction)
- [ ] Personal graph rebuild route (`/v1/admin/hnsw/personal/rebuild`) tested after new owner data

### Sinatra / GBT / IMBHS

- [ ] GBT model exists per owner who has done ≥ 1 inference (`POST /v1/frank/gbt`)
- [ ] Parking queue is not stale — no owner has > 200 parked partitions unprocessed
- [ ] Tone overrides are reasonable: temperature stays in [0.4, 1.0] range
- [ ] HarmonyMemory not overflowing: memory_size respected in IMBHS state
- [ ] `POST /v1/frank/reset` tested: confirm Sinatra state fully clears and re-initializes on next inference
- [ ] Technical indicator computation: EMA, MACD, Stochastic K/D produce finite, non-NaN values
- [ ] Sentiment scores don't degenerate (all partitions scoring 0.0 = broken lexicon or no text)
- [ ] GBT training doesn't overfit (check via Frank: tree depth, leaf values should be < ±3)

### Gita / Royalty / Wallet

- [ ] Every inference that uses ≥ 1 partition creates a `CreditExchange` record
- [ ] Royalty math: sum of all `contributions.credits` + `service_charge` ≈ `total_credits` (floating point tolerance ±0.001)
- [ ] No owner wallet has negative balance
- [ ] `non_self_earnings` field tracks cross-owner royalties correctly (owner A's doc used by owner B → A earns)
- [ ] `Gita.Registry.market_weight` stays normalized: all weights should sum to approximately 1.0 within an owner's documents
- [ ] `performance_score` is in [0.0, 1.0] for all documents
- [ ] `WalletRegistry` persists and loads correctly across server restart
- [ ] `Gita.Registry` persists and loads correctly across server restart
- [ ] Stream billing: final token count in `Gita.Payload` matches actual `usage.total_tokens` from LLM response
- [ ] Peer results in `Gita.Payload.peer_results` are populated when Oracle is enabled

### Oracle / P2P

- [ ] `--enable-oracle` starts without errors
- [ ] Seed peers connect within 5s of startup
- [ ] `GET /oracle/nodes` returns accurate peer list
- [ ] Trust scores update after query (success → score increases, failure/timeout → score decreases)
- [ ] `visited_nodes` prevents cycles in query propagation
- [ ] Hop limit respected: no query propagates beyond `hop_limit = 3`
- [ ] Gossip: `nodeJoined` event reaches all connected peers within 10s
- [ ] Peer results are marked `isPeer: true` in SearchResult
- [ ] WebSocket reconnection: manually disconnect a peer, verify reconnection within 30s
- [ ] `POST /oracle/peers` adds peer to topology without restart

### Marielle

- [ ] `open` returns a question with confidence > 0 when owner has ≥ 5 personal HNSW nodes
- [ ] `proactive` returns `should_interject: false` for a completely new topic (no personal graph match)
- [ ] `proactive` returns `should_interject: true` for a topic the owner has explored
- [ ] `interject` question references content from the owner's personal graph (trace via `source_partition_id`)
- [ ] `bridge` requires both owners to have `bridging_enabled = true` — returns error if not
- [ ] Confidence values are in [0.0, 1.0]
- [ ] Jaccard distance computation doesn't panic on empty message list
- [ ] Marielle never surfaces restricted documents in bridge output

### Chat Completions

- [ ] Non-stream response includes `usage.total_tokens`
- [ ] Stream response ends with `data: [DONE]`
- [ ] RAG context is injected into system prompt (visible in LLM call)
- [ ] Sinatra tone actually changes temperature: run with strongly negative content, verify lower temp
- [ ] Prompt cache: second message in session uses cached prefix (check metrics `prompt_cache_hits`)
- [ ] No Sinatra inference failure blocks the chat response (graceful fallback to defaults)
- [ ] No Oracle timeout blocks the chat response (proceeds with local results)
- [ ] `POST /v1/completions` works for plain text (no message history)
- [ ] `POST /v1/tools/summarize` works without RAG retrieval

### Auth

- [ ] Invalid JWT returns 401
- [ ] Expired JWT returns 401
- [ ] Valid JWT correctly injects `owner_id` into request storage
- [ ] `POST /v1/auth/sign-in` returns token pair
- [ ] `POST /v1/auth/refresh` rotates tokens
- [ ] Admin middleware: non-admin owner gets 403 on admin routes
- [ ] Admin middleware: valid admin owner_id gets 200

### Storage (Backup/Restore)

- [ ] `POST /v1/storage/backup` creates a manifest in Supabase
- [ ] `POST /v1/storage/manifest` retrieves the manifest
- [ ] `POST /v1/storage/restore` re-indexes documents into HNSW (verify node count increases)
- [ ] `POST /v1/storage/purge` wipes ALL data — verify HNSW node count = 0, wallet = 0
- [ ] Partial purge (`/documents/purge`, `/groups/purge`) only removes the specified data

---

## Cross-Cutting Concerns

### Concurrency Safety

- [ ] No direct mutation of `SewnRegistry` outside of `RegistryMutator` actor
- [ ] No direct HNSW mutation outside of `TableMutator` or `PersonalHNSWMutator` actors
- [ ] `IndexQueue` is used for all embed→insert cycles (not bypassed)
- [ ] No shared mutable state accessed from route handlers directly (all through actors)

### Persistence Integrity

- [ ] All JSON persistence goes through `PersistenceActor`
- [ ] Server restart: all registries reload correctly (HNSW, Sinatra, Gita, Sewn)
- [ ] WAL replay doesn't produce duplicate nodes on crash recovery
- [ ] `~/.sewn/` directory has appropriate permissions (not world-readable)

### Metrics & Observability

- [ ] `GET /metrics` returns Prometheus metrics
- [ ] Key counters exist: requests by route, HNSW node count, inference count
- [ ] IP metrics middleware increments per-IP counter
- [ ] No metric registration panics at startup

### API Compatibility

- [ ] Chat completion response shape is OpenAI-compatible (`object: "chat.completion"`)
- [ ] Embedding response shape is OpenAI-compatible
- [ ] Model list response is OpenAI-compatible (`object: "list"`, `data: [...]`)
- [ ] `POST /v1/completions` is OpenAI text completion compatible

---

## Audit Frequency Recommendations

| System | When to Audit |
|--------|--------------|
| Sewn registry/HNSW | Weekly + after any mass document operation |
| Sinatra GBT | Monthly + when users report off-tone responses |
| Gita wallet | After every release that touches royalty logic |
| Oracle | After adding/removing peers, or after network incident |
| Marielle | After personal graph changes or personal HNSW rebuild |
| Full system | Before every production release |
