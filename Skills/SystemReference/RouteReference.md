# Route Reference

Every route Sewn registers, as of the current source. Registration happens in
`configureRoutes(_:_:modelProvider:isVLM:)` and
`configureWebSocketRoutes(_:modelProvider:)` in `Sources/SewnServer.swift`.

> **All routes must be registered before `Application.init`.** It freezes the
> responder; a route added afterwards is silently unreachable.

Route trees:

```
router                              — open, no auth
  └── router.add(AuthMiddleware())  — "protected"
  └── router.add(AdminMiddleware()) — "admin"

wsRouter (BasicWebSocketRequestContext) — bearer checked in shouldUpgrade
```

---

## Open Routes (no auth)

| Method | Path | File | Notes |
|--------|------|------|-------|
| `GET` | `/health` | `Health.swift` | Note: registered as `"health"`, no leading slash |
| `GET` | `/metrics` | `Metrics.swift` | Prometheus text. Guarded by `METRICS_TOKEN` |
| `GET` | `/v1/stats` | `Stats.swift` | Public document + group counts. **Rate limited per IP → 429** |
| `GET` | `/v1/threads` | `Thread.swift` | Registered Thread nodes + mothership id |
| `POST` | `/v1/auth/sign-up` | `Auth.swift` | |
| `POST` | `/v1/auth/sign-in` | `Auth.swift` | |
| `POST` | `/v1/auth/verify` | `Auth.swift` | OTP — signup / recovery / magic link |
| `POST` | `/v1/auth/refresh` | `Auth.swift` | |
| `POST` | `/v1/auth/reset-password` | `Auth.swift` | |

`POST /v1/auth/sign-in`:

```json
// Request
{ "email": "user@example.com", "password": "secret" }
// Response
{ "accessToken": "...", "refreshToken": "...", "expiresIn": 3600, "userId": "uuid" }
```

---

## Protected Routes

`AuthMiddleware` validates the Supabase bearer token, populates
`context.authUserId`, and **overwrites `sewn.owner_id`** with the JWT-derived id
(lowercased). A client cannot address another owner's data by editing the body.

### Generation

| Method | Path | File | Notes |
|--------|------|------|-------|
| `POST` | `/v1/chat/completions` | `ChatCompletions.swift` | Persona + RAG + Gita. JSON or SSE on `stream` |
| `POST` | `/v1/complete` | `Complete.swift` | One bounded generation. No persona, RAG, or Gita. No `sewn` object |
| `POST` | `/v1/skills/complete` | `SkillsComplete.swift` | Keeps roles, takes a tool roster, may return `tool_calls` |
| `POST` | `/v1/code/complete` | `CodeComplete.swift` | Pair-coding tool roster. Model pinned to `ModelConfig.codingModel`. maxTokens clamped to 32–4096 (default 2048) |
| `POST` | `/v1/vision/look` | `VisionLook.swift` | Mistral vision. Describe a screen region or compose a Design Plan. Nothing retained |
| `POST` | `/v1/tools/summarize` | `Tools.swift` | Single-shot. No RAG, no Sinatra |
| `POST` | `/v1/speak` | `Speak.swift` | Mistral TTS proxy, PCM stream |

`POST /v1/chat/completions`:

```json
// Request
{
  "messages": [{ "role": "user", "content": "Summarize my notes on HNSW." }],
  "model": "mistral-medium-latest",
  "personality": "scholar",
  "provider": "mistral",
  "stream": false,
  "sewn": { "owner_id": "uuid" }
}
// Response (stream: false)
{
  "choices": [{ "message": { "role": "assistant", "content": "..." }, "finishReason": "stop" }],
  "usage": { "prompt_tokens": 120, "total_tokens": 350 },
  "personality": "scholar",
  "contribution": { "owners": [{ "spans": [], "document_spans": { "did": [{ "lower": 0, "upper": 42 }] } }] }
}
```

`stream: true` → SSE deltas, then a trailing chunk with empty `choices` plus
`contribution` and `auto_memory`, then `data: [DONE]`.

### Providers

| Method | Path | File | Notes |
|--------|------|------|-------|
| `GET` | `/v1/providers` | `Providers.swift` | Every backend: `available`, `state`, `progress`, `model`, `capabilities`, `reason` |
| `POST` | `/v1/providers/local/warm` | `Providers.swift` | Load the on-device model now. Idempotent — a warm in flight is joined |

### Embeddings

| Method | Path | File | Notes |
|--------|------|------|-------|
| `POST` | `/v1/embeddings` | `Embeddings.swift` | **INGEST.** Chunks, tags, fans out to ONE Thread node. Returns as soon as enqueued |
| `POST` | `/v1/embed` | `EmbedVectors.swift` | **Returns the vector.** No storage side effect. No `sewn` object |

```json
// POST /v1/embeddings
{
  "inputs": [{ "values": ["chunk a", "chunk b"] }, { "values": ["chunk c"] }],
  "model": "mistral-embed",
  "sanitize": false,
  "sewn": { "owner_id": "uuid" }
}
// sanitize: true runs TextChunker first (1500 chars max).
// Embedding happens on Thread, not here.
```

Thread backpressure is retried three times with jittered backoff
(500 ms / 1 s / 2 s) before the batch is dropped with a warning.

### Search & Graph

| Method | Path | File | Notes |
|--------|------|------|-------|
| `POST` | `/v1/search` | `Search.swift` | Fan-out to all active nodes; merged, re-ranked, deduped |
| `POST` | `/v1/graph` | `Graph.swift` | Knowledge-graph query. **400** unless `entity` and/or `query` is present |

```json
// POST /v1/search
{ "query": "what did I write about distributed systems?", "sewn": { "owner_id": "uuid" } }
// Response
{ "texts": ["..."], "references": ["document-id-1"], "contribution": { "document-id-1": 0.87 } }
```

```json
// POST /v1/graph
{
  "sewn": { "owner_id": "uuid" },
  "entity": "HNSW",
  "query": "graph traversal",
  "kinds": ["concept"],
  "hops": 1,
  "limit": 20,
  "include_documents": true
}
// Response: { "object": "graph", "entities": [...], "relationships": [...],
//             "documents": [...], "stats": { "entity_count": n, "relationship_count": n } }
```

### Documents & Groups

| Method | Path | File | Notes |
|--------|------|------|-------|
| `POST` | `/v1/list/documents` | `List.swift` | Via `fanoutLibrary` |
| `POST` | `/v1/list/groups` | `List.swift` | Via `fanoutLibrary` |
| `POST` | `/v1/list/groups/documents` | `List.swift` | Via `fanoutLibraryByDocuments` — reverse map, no full scan |
| `POST` | `/v1/modify` | `Modify.swift` | `operation`: `remove` \| `access` \| `group` |
| `POST` | `/v1/modify/group/access` | `Modify.swift` | |
| `POST` | `/v1/modify/group/metadata` | `Modify.swift` | Label and metadata |
| `POST` | `/v1/modify/group/remove` | `Modify.swift` | Deletes the group and its documents |

```json
// POST /v1/modify
{ "update": { "operation": "remove", "documentId": "did" }, "sewn": { "owner_id": "uuid" } }
```

All three operations reach Thread — `remove` via `fanoutRemove`, `access` and
`group` via `fanoutUpdateDocument`. Thread is the source of truth, so none of
them writes ownership data locally.

### Infinite

| Method | Path | File | Notes |
|--------|------|------|-------|
| `GET` | `/v1/infinite/leaderboard` | `Infinite.swift` | Query: `page` (default 1), `page_size` (clamped 1–100, default 20) |
| `POST` | `/v1/infinite/search` | `Infinite.swift` | Search across public groups |

Leaderboard score: earnings 40%, retrieval count 30%, average sentiment 20%,
document count 10% — min-max normalized across all public groups **at request
time**. No score is persisted.

### Personalities & Profile

| Method | Path | File | Notes |
|--------|------|------|-------|
| `GET` | `/v1/personalities` | `Personalities.swift` | Persona list |
| `GET` | `/v1/profile` | `Profile.swift` | Query param `userId` |
| `PATCH` | `/v1/profile` | `Profile.swift` | Update display name |
| `POST` | `/v1/feedback` | `Forms.swift` | User feedback ingestion |

### Wallet

| Method | Path | File | Notes |
|--------|------|------|-------|
| `GET` | `/v1/wallet` | `Wallet.swift` | `totalEarnings`, `balance`, `totalSpent`, `totalCashedOut`, per-group breakdown |

### Frank — Sinatra Debug

| Method | Path | File | Notes |
|--------|------|------|-------|
| `POST` | `/v1/frank/gbt` | `Frank.swift` | Full GBT state — trees, hyperparameters, feature names |
| `POST` | `/v1/frank/parking` | `Frank.swift` | Live pipeline snapshot: parked entries, last search adjustments |
| `POST` | `/v1/frank/reset` | `Frank.swift` | Wipe all Sinatra state for the caller |
| `POST` | `/v1/frank/export` | `Frank.swift` | Export Sinatra state |
| `POST` | `/v1/frank/import` | `Frank.swift` | Import previously exported state |

### Marielle — all 503

| Method | Path | Status |
|--------|------|--------|
| `POST` | `/v1/marielle/open` | **503** |
| `POST` | `/v1/marielle/proactive` | **503** |
| `POST` | `/v1/marielle/interject` | **503** |
| `POST` | `/v1/marielle/bridge` | **503** |

`"Marielle requires Thread-hosted HNSW graph — not yet implemented"`. See
`Skills/Marielle/README.md`.

### Auth (session required)

| Method | Path | Notes |
|--------|------|-------|
| `POST` | `/v1/auth/sign-out` | Registered on the protected tree — needs a live session |

---

## WebSocket

| Path | File | Notes |
|------|------|-------|
| `/v1/realtime/chat` | `Realtime/Realtime.swift` | Bearer validated in `shouldUpgrade`. One turn per connection |

Client sends `{"type":"turn.start","request":{…ChatCompletionRequest…},"tts":{…}}`;
server streams phase / token / audio.begin / PCM / metadata / turn.end frames.
`{"type":"cancel"}` or a socket close cancels everything — that is barge-in. See
`Skills/Realtime/README.md`.

---

## Admin Routes

`AdminMiddleware` performs the same Supabase validation as `AuthMiddleware`, then
asserts the caller **is** the single designated admin:

```swift
private static let adminUserId = ProcessInfo.processInfo.environment["ADMIN_USER_ID"] ?? ""
guard user.userId.lowercased() == Self.adminUserId.lowercased() else {
    throw HTTPError(.forbidden, message: "Admin access required")
}
```

Not an allowlist — **one** account, from `ADMIN_USER_ID`. Unset means no one is
admin (every admin route 403s), which is the safe default.

Admin routes use the body's `owner_id` as the **target**, not the caller's id.
That is the point of them.

| Method | Path | Status | Notes |
|--------|------|--------|-------|
| `POST` | `/v1/admin/list/owners` | **Stub** | Returns `{ owners: [] }` |
| `POST` | `/v1/admin/list/documents` | **Stub** | Returns `{ documents: [], access: {} }`; logs the target |
| `POST` | `/v1/admin/list/groups` | **Stub** | Returns `{ groups: [], access: {} }`; logs the target |
| `POST` | `/v1/admin/modify` | **Implemented** | Any document, for any owner |
| `POST` | `/v1/admin/modify/group` | **Implemented** | Any group |
| `POST` | `/v1/admin/sinatra/gbt` | **Implemented** | GBT state for any owner |
| `GET` | `/v1/admin/model` | **Implemented** | Current chat + utility model |
| `PUT` | `/v1/admin/model` | **Implemented** | Runtime override. Not persisted — restart returns to `.env` |
| `PUT` | `/v1/admin/personalities` | **Implemented** | Replace the persona list |
| `POST` | `/v1/admin/owner/delete` | **Implemented** | `removeAll` + `sinatra.removeOwner` |
| `POST` | `/v1/admin/system/stats` | **Stub** | All zeroes |
| `POST` | `/v1/admin/audit/stale` | **Stub** | `{ scanned: 0, stale: [] }` |
| `POST` | `/v1/admin/audit/reconcile` | **Stub** | All zeroes |

> `POST /v1/admin/owner/delete` returns `documentsRemoved` from
> `sewn.removeAll(...)`, which **currently returns 0** — Sewn no longer keeps a
> local document list to count, and Thread does the filtering. `sinatraCleared`
> is accurate.

The three list stubs and the audit pair are stubs for the same reason: they were
registry scans, and the registry no longer holds documents. Reimplementing them
means fan-out to Thread with an admin scope.

### Removed admin routes

`/v1/admin/hnsw/stats`, `/v1/admin/hnsw/personal`, `/v1/admin/hnsw/personal/rebuild`,
`DELETE /v1/admin/hnsw/node`, `/v1/admin/hnsw/compact`, and
`/v1/admin/table/document` are all gone — not 503, **not registered**. The
`registerAdminRoutes` doc comment still lists three of them; that comment is
stale in the source.

---

## The `sewn` Request Object

Accepted by every protected route (except `/v1/complete`, `/v1/embed`,
`/v1/vision/look`, which have no scope object at all):

```json
{
  "sewn": {
    "owner_id": "uuid",
    "group": { "id": "gid", "label": "Group Name" },
    "groups": [{ "id": "gid" }],
    "entities": ["Entity"],
    "tags": ["tag"],
    "aggregate": true,
    "scope": "personal",
    "thread_ids": ["thread-uuid"],
    "personal_thread_id": "thread-uuid",
    "request_id": "uuid"
  }
}
```

| Field | Meaning |
|-------|---------|
| `owner_id` | Overwritten by `AuthMiddleware` on non-admin routes; **lowercased** |
| `scope` | `global` \| `personal`, forwarded to Thread |
| `aggregate` | Merge across groups |
| `thread_ids` | Pin the request to specific nodes; chooses the index target |
| `entities` / `tags` | Entity hints for graph-first retrieval (`entities ?? tags`) |
| `request_id` | Log correlation |

---

## Removed Route Families

| Family | Status |
|--------|--------|
| `/v1/hnsw/*` (14 routes) | **Removed.** HNSW is Thread's |
| `/v1/admin/hnsw/*` | **Removed** |
| `/v1/admin/table/document` | **Removed** |
| `/v1/storage/backup`, `/manifest`, `/restore`, `/purge`, `/purge/documents`, `/purge/groups` | **Removed.** No Supabase Storage backup/restore surface |
| `/v1/batch/embeddings` | **Removed.** `/v1/embeddings` takes batches |
| `/v1/models` | **Removed.** Use `GET /v1/providers` |
| `/v1/completions` | **Renamed** to `/v1/complete`, and narrowed |
| `/v1/modify/group` | **Split** into `/access` and `/metadata` |
| `/oracle/*` | **Removed** with the P2P mesh |

---

## Conventions for a New Route

1. Write `registerXRoute(_ router: some RouterMethods<SewnRequestContext>, …)` in
   its own file under `Sources/API/Routes/`.
2. Call it from `configureRoutes` on the right tree — **before**
   `Application.init`.
3. Resolve scope with `try body.sewn.from(context)`, never by trusting
   `body.sewn.ownerId` directly.
4. Reach Thread only through a `fanout*` primitive.
5. Request/response models go in `Sources/API/Models/Requests|Responses/`, with
   snake_case `CodingKeys`.
6. **Read the body exactly once.** It iterates once; a second `decode` traps.
7. Map an unavailable provider to 503 via `ProviderUnavailable`, an unknown one
   to 400.
