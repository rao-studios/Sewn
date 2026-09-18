# Feature Auditing

Per-system audit checklists. Run these when landing a large change, after a
refactor, before a release, or when a system has been dormant.

Each list is written to be checkable from the outside — a route, a metric, or a
log line — rather than by reading code.

---

## Sewn — Orchestration

- [ ] `GET /v1/threads` lists every expected node with `is_active: true`
- [ ] At least one node reports `accepting_storage: true`
- [ ] `sewn.index.queue_depth` returns to 0 after an ingest burst
- [ ] No "batch dropped" warnings in logs (three retries, then silent data loss)
- [ ] Put coalescing holds: a burst of single-document indexes for one owner and
      group produces **one** fan-out, not N
- [ ] Ordering holds: a remove submitted after a put never lands first
- [ ] `POST /v1/embeddings` responds before indexing completes (it is
      fire-and-forget by design)
- [ ] Owner → node affinity works: a document indexed to node A is still found
      after a search fan-out
- [ ] A killed Thread node degrades recall without failing the turn
- [ ] With **zero** nodes, search returns empty and nothing throws

### Registry

- [ ] `SewnRegistry` contains only `documentStats` and `bridgingEnabledOwners` —
      no document, group, or ownership data has crept back in
- [ ] A registry file written before the Thread split still decodes
- [ ] `registry-wal` grows on inference and truncates at checkpoint (16 MB)
- [ ] Kill -9 then restart: earnings accumulated since the last checkpoint are
      still present (WAL replay)
- [ ] Clean shutdown flushes — `flushForShutdown` saves *then* truncates
- [ ] Nodes unseen for 300 s are purged; `isActive` is a 60 s window

---

## Sinatra — Sentiment & Learning

- [ ] `sinatra.unadjusted_total{reason}` is not dominated by one reason.
      All-`no_model` means training never runs
- [ ] `POST /v1/frank/gbt` returns a model for any owner who has passed the
      training gate
- [ ] `POST /v1/frank/parking` shows parked entries, and **never more than 30**
      for one owner
- [ ] The word-count gate blocks: a 3-word reply clears parked entries and skips
      sentiment entirely
- [ ] Resonance confidence below 0.55 is treated as a miss
- [ ] The verbatim-substring guard rejects a paraphrased excerpt
- [ ] Resonance documents land in the `"Resonance"` group, and that group is
      **not billable**
- [ ] Session boundary requires **both** pace collapse and attentiveness reset
- [ ] `SinatraTone` stays within bounds — temperature in [0.25, 0.40], top-p in
      [0.75, 0.90]
- [ ] Higher retrieval confidence **lowers** temperature (the direction is easy
      to invert by accident)
- [ ] Technical indicators produce finite, non-NaN values
- [ ] IMBHS respects `warmup` (20) and `cadence` (5), and applies a new harmony
      only on ≥1% MAE improvement
- [ ] `HarmonyMemory` encodes without a non-finite `Double` (property lists
      cannot hold `.infinity`)
- [ ] `POST /v1/frank/reset` clears everything and the next turn re-initializes
- [ ] Export → reset → import round-trips
- [ ] A Sinatra failure does not fail the chat turn — tone falls back to `.base`

---

## Gita — Attribution & Money

- [ ] Invariant on every priced turn:
      `owners.map(\.earning).sum + serviceCharge == totalCost` (±0.001)
- [ ] `royalty` sums to 1.0 across owners; `influence` sums to 1.0 within each
      owner
- [ ] Word counts accumulate in one pass — the same document appearing in several
      partitions is counted once, not per-owner
- [ ] Empty partitions and zero total word count return an empty contribution
      rather than dividing by zero
- [ ] Co-owned documents split **equally**
- [ ] A partition with an empty `ownerId` is attributed to its `threadId`
- [ ] **An owner earns nothing from querying their own documents**
      (`ownerId != spenderId`)
- [ ] No wallet has a negative balance
- [ ] `totalSpent` and `totalCashedOut` are derived, and agree with the records
- [ ] A new wallet starts at `initialBalance` (1,000,000)
- [ ] The token ledger includes resonance, sentiment, compaction, and auto-memory
      calls — not just the generation
- [ ] **Every model in use has a pricing entry.** A model absent from the catalog
      silently prices at `mistral-medium` rates
- [ ] Surge multiplier is 1.0 at zero load and `maxSurgeMultiplier` at the
      ceiling; 1.15× at load 1 of 10 is expected
- [ ] Three `service: .gita, flow: .chat` log lines appear per priced turn

### Spans

- [ ] `[[n]]` markers are stripped from **every** response — non-stream, each SSE
      delta, and each realtime token — whether or not a contribution exists
- [ ] Span offsets index the **stripped** text
- [ ] An unknown marker index strips silently with no attribution
- [ ] A marker run (`[[1]][[3]]`) attributes the sentence to both sources
- [ ] Exact spans win over heuristic spans on overlap
- [ ] Verbatim-context turns (≤6000 partition chars) still produce spans, via the
      marker and heuristic tiers only

---

## Chat & Completions

- [ ] Non-stream responses include `usage`
- [ ] Streams end with `data: [DONE]` after the trailing metadata chunk
- [ ] The trailing chunk carries `contribution` and `auto_memory` with empty
      `choices`
- [ ] Parameter precedence: request > personality > tone > defaults for
      temperature and top-p; **tone first** for the repetition controls
- [ ] A thinking model receives at least `thinkingTokenFloor` (4096) tokens
- [ ] A personality's `modelOverride` applies, and an explicit request `model`
      beats it
- [ ] `client: "bonnie"` reframes retrieved context as support, and
      `bonnie-tool-…` documents render as a separate non-recitable tier
- [ ] Compaction is skipped at or under 6000 partition characters
- [ ] `sourceIndex` order matches the rendered `[n]` tag order
- [ ] Zero retrieval results still produce an answer
- [ ] `/v1/complete`, `/v1/skills/complete`, `/v1/code/complete` run **no**
      persona, RAG, or Gita
- [ ] `/v1/embed` has **no storage side effect** — the corpus is unchanged after
      calling it
- [ ] A mid-stream client disconnect bills the tokens actually sent

---

## Realtime

- [ ] Bearer validation happens in `shouldUpgrade` — an unauthorized client never
      gets a socket
- [ ] `audio.begin` is emitted **once**, before the first PCM frame
- [ ] Frame ordering is deterministic (single writer loop)
- [ ] `sewn.realtime.first_audio` is well below `sewn.realtime.retrieval_wait` —
      otherwise the two-pass design is buying nothing
- [ ] The grounded pass continues the opening rather than restarting it
- [ ] TTS failure emits `.ttsFailed` and text continues
- [ ] Retrieval failure produces a complete answer under `degradedInstruction`
- [ ] `{"type":"cancel"}` and a socket close both cancel all in-flight work
- [ ] On the `local` provider the opening pass is skipped
- [ ] Opening text is not attributed
- [ ] The `metadata` frame decodes with the SSE chunk Codable

---

## Providers

- [ ] `GET /v1/providers` lists all three with accurate `available` and `state`
- [ ] Every unavailable provider has a **non-nil `reason`**
- [ ] A missing key is a 503 naming the variable, never a crash
- [ ] An unknown `provider` value is a 400
- [ ] `local` on a non-macOS build reports `localNotBuilt`
- [ ] A cross-family model is ignored, not rejected — a `tinker://` id can never
      reach Mistral's host
- [ ] `POST /v1/providers/local/warm` is idempotent; a warm in flight is joined
- [ ] With `SEWN_LOCAL_UTILITY=0`, a `local` turn makes **no outbound request at
      all**
- [ ] `SEWN_GLOBAL_LLM` set to nonsense falls back to mistral without failing
      startup
- [ ] `PUT /v1/admin/model` takes effect immediately and does not survive restart

---

## Auth & Admin

- [ ] Missing, malformed, invalid, and expired bearer tokens all 401
- [ ] `AuthMiddleware` **overwrites** `sewn.owner_id` — a forged body id cannot
      reach another owner's data
- [ ] Owner ids are lowercased everywhere
- [ ] A valid non-admin user gets 403 on `/v1/admin/*`
- [ ] `ADMIN_USER_ID` unset ⇒ every admin route 403s
- [ ] Admin routes use the **body's** `owner_id` as the target
- [ ] `POST /v1/admin/owner/delete` clears Sinatra state (`sinatraCleared`
      accurate) and fans a remove out to Thread. Note `documentsRemoved` is
      currently always 0
- [ ] `/v1/auth/sign-out` requires a live session
- [ ] Open routes are only: `/health`, `/metrics`, `/v1/stats`, `/v1/threads`,
      and the five unauthenticated auth routes

---

## Graph & Stats

- [ ] `POST /v1/graph` with neither `entity` nor `query` returns 400
- [ ] `hops` is clamped to 0–3
- [ ] Merge semantics: entity `mentionCount` **summed** and `score` **max**;
      relationship `weight` summed; stats summed
- [ ] Empty-string `name` / `owner_id` normalize to `null`
- [ ] `GET /v1/stats` counts only `access == .available` groups
- [ ] `/v1/stats` rate limiter returns 429, and resolves the client IP from the
      first `X-Forwarded-For` entry

---

## Cross-Cutting

### Concurrency

- [ ] No `SewnRegistry` mutation outside `RegistryMutator`
- [ ] No index mutation bypassing the `WriteJob` queue
- [ ] One `PersistenceActor` per file — none shared
- [ ] Hot-path reads use `nonisolated` snapshots, not actor hops
- [ ] No read-modify-write split across two lock acquisitions

### Persistence

- [ ] All state under one root: `--data-dir`, then `SEWN_DATA_DIR`, then
      `~/Documents/sewn-db`
- [ ] Every persisted type decodes an older file (tolerant `decodeIfPresent`)
- [ ] No non-finite `Double` reaches a property list
- [ ] Restart reloads registry, Sinatra, wallet, personalities, and node identity
- [ ] The data directory is not world-readable

### Route registration

- [ ] Every route is registered before `Application.init`
- [ ] New routes sit on the correct tree (open / protected / admin)
- [ ] No handler decodes the request body twice

### Observability

- [ ] Under `--server-mode`, `GET /metrics` returns Prometheus text and is gated
      by `METRICS_TOKEN`; without the flag the route is absent and answers
      like any unknown path (401 from the auth layer)
- [ ] Log lines carry a `service` field, so Cockpit's `service_name` label
      populates
- [ ] Conduit session logs appear under `service: "Sewn"`
- [ ] `requestId` correlates a turn end-to-end across services
- [ ] No metric registration failure at startup

---

## Audit Frequency

| System | When |
|--------|------|
| Thread fleet + queue depth | Continuously, alerting |
| Gita invariants | After any release touching royalty, pricing, or spans |
| Providers | On deploy and on key rotation |
| Sinatra gates | Monthly, or on a tone complaint |
| Registry / WAL | Weekly, and after any billing-field change |
| Realtime latency | After any change to the turn engine or compaction |
| Everything | Before every production release |

---

## Retired Checklists

Audits for `TableMutator`, `PersonalHNSWMutator`, `IndexQueue`, `PartitionTable`,
PQ codebooks, HNSW invariants and compaction, the Oracle P2P mesh (trust scores,
gossip, hop limits, `visited_nodes`), Supabase Storage backup/restore, and the
`/v1/hnsw/*` route family have all been removed — that code is either in the
Thread repository or deleted. If you are looking for HNSW graph health, audit it
on the Thread nodes.
