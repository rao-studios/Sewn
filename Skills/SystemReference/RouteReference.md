# API Route Reference

Complete reference for all ~80 endpoints. Protected routes require `Authorization: Bearer <supabase_jwt>`.
Admin routes additionally require the requesting owner to be in the admin allowlist.

---

## Auth Routes (Public — No Token Required)

### `POST /v1/auth/sign-in`
Email + password login.
- **Request**: `{ email, password }`
- **Response**: `{ access_token, refresh_token, user: { id, email } }`
- **Logic**: Delegates to Supabase Auth. Returns JWT pair.

### `POST /v1/auth/sign-up`
Register a new user account.
- **Request**: `{ email, password }`
- **Response**: `{ user: { id, email }, session? }`
- **Logic**: Creates Supabase user. May require email verification depending on project settings.

### `POST /v1/auth/verify`
Verify OTP token for signup, recovery, or magic link flows.
- **Request**: `{ email, token, type }` — type is `signup | recovery | magiclink`
- **Response**: `{ access_token, refresh_token }`

### `POST /v1/auth/refresh`
Refresh an expired access token.
- **Request**: `{ refresh_token }`
- **Response**: `{ access_token, refresh_token }`

### `POST /v1/auth/reset-password`
Send password reset email.
- **Request**: `{ email }`
- **Response**: `{ message }`

### `POST /v1/auth/sign-out`
Invalidate the current session.
- **Request**: Bearer token in header
- **Response**: 200 OK

---

## System Routes

### `GET /health`
Health check. Always returns 200 if server is up.
- **Auth**: None
- **Response**: `{ status: "ok" }`

### `GET /metrics`
Prometheus metrics scrape endpoint.
- **Auth**: None (open — secure at network level)
- **Response**: Prometheus text format (counters, histograms by route and IP)

### `GET /v1/models`
List available LLM models loaded in this server instance.
- **Auth**: None
- **Response**: `{ data: [{ id, object: "model", created, owned_by }] }`
- **Logic**: Returns the model(s) loaded at startup from CLI args.

---

## Chat & Completions

### `POST /v1/chat/completions`
Primary chat endpoint. Supports streaming (SSE) and non-streaming responses.
- **Auth**: Bearer token required
- **Request** (OpenAI-compatible):
  ```json
  {
    "model": "string",
    "messages": [{ "role": "user|assistant|system", "content": "string" }],
    "stream": false,
    "temperature": 0.7,
    "top_p": 0.9,
    "max_tokens": 512
  }
  ```
- **Response (non-stream)**: OpenAI ChatCompletion JSON
- **Response (stream)**: `text/event-stream` SSE with `data: {...}` chunks
- **Business Logic**:
  1. Embed final user message
  2. Search Seer for relevant partitions (local + Oracle peers if enabled)
  3. Sinatra infers GBT sentiment → adjusts temperature/top_p/repetition_penalty
  4. Build system prompt with retrieved context
  5. Call ModelProvider (Mistral API or local MLX)
  6. Track inference in Gita (royalty calculation)
  7. Park partitions in Sinatra for background GBT training
- **Tone Override**: If Sinatra returns a strong tone adjustment, it overrides request-level temperature.

### `POST /v1/completions`
Plain text completion (non-chat). Same auth and LLM flow, no message history.
- **Request**: `{ model, prompt, stream, max_tokens, temperature }`
- **Response**: OpenAI Completion JSON

---

## Embeddings & Indexing

### `POST /v1/embeddings`
Embed and index a single document chunk.
- **Auth**: Bearer token required
- **Request**:
  ```json
  {
    "input": "text to embed",
    "model": "optional-model-id",
    "document_id": "uuid",
    "url": "source-url",
    "owner_id": "uuid"
  }
  ```
- **Response**: `{ embedding: [float], document: { id, url }, partition: { id } }`
- **Business Logic**:
  1. Call EmbeddingModelProvider → float32 vector
  2. `Seer.put()` → insert into HNSW (global + personal) + PQ partition table
  3. `Gita.track(.put)` → register document as market security
  4. Auto-memory: if owner has auto-memory enabled, index in personal HNSW too

### `POST /v1/batch/embeddings`
Embed and index multiple document chunks in one call.
- **Auth**: Bearer token required
- **Request**: `{ inputs: [{ text, document_id, url }], model? }`
- **Response**: `{ results: [{ embedding, document, partition }] }`
- **Logic**: Sequential or concurrent embedding (controlled by `IndexQueue` to prevent HNSW reentrancy).

---

## Search

### `POST /v1/search`
Semantic vector search.
- **Auth**: Bearer token required
- **Request**:
  ```json
  {
    "query": "search text",
    "owner_id": "uuid",
    "scope": "global|personal|group",
    "group_id": "uuid (optional)",
    "top_k": 5,
    "threshold": 0.75
  }
  ```
- **Response**:
  ```json
  {
    "results": [{
      "partition_id": "uuid",
      "document_id": "uuid",
      "text": "...",
      "score": 0.89,
      "owner_id": "uuid"
    }]
  }
  ```
- **Business Logic**:
  1. Embed query
  2. `Seer+QueryExpander`: generate N query variants (paraphrase + keyword) to improve recall
  3. HNSW traversal for each variant → union candidate set
  4. PQ rerank candidates → cosine similarity on compressed embeddings
  5. Apply access control filter (registry.access)
  6. If Oracle enabled: fan out to peers via `Seer+Peer`, merge results
  7. Return top-K above threshold

---

## Document Management

### `POST /v1/modify`
Modify a document's access level, group membership, or delete it.
- **Auth**: Bearer token (owner must own the document)
- **Request**:
  ```json
  {
    "document_id": "uuid",
    "action": "set_access|add_to_group|remove_from_group|delete",
    "access": "available|restricted",
    "group_id": "uuid"
  }
  ```
- **Response**: `{ success: true, document: { id, access } }`
- **Logic**: Routes to `RegistryMutator` for metadata, `TableMutator` for HNSW node deletion if deleting.

### `POST /v1/modify/group`
Change a group's access level.
- **Auth**: Bearer token (group owner)
- **Request**: `{ group_id, access: "available|restricted" }`
- **Response**: `{ success: true, group: { id, access } }`

### `DELETE /v1/modify/group/remove`
Remove a group entirely (does not delete documents).
- **Auth**: Bearer token (group owner)
- **Request**: `{ group_id }`
- **Response**: `{ success: true }`

---

## Listing

### `POST /v1/list/documents`
List all documents owned by the authenticated user.
- **Auth**: Bearer token
- **Request**: `{ owner_id, page?, limit? }`
- **Response**: `{ documents: [{ id, url, created_at, group_ids, access, stats }] }`

### `POST /v1/list/groups`
List all groups the authenticated user owns.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ groups: [{ id, label, document_ids, access, total_earnings }] }`

---

## Storage Management

### `POST /v1/storage/backup`
Backup all user documents and metadata to Supabase storage.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ manifest_id, documents_count, partitions_count }`
- **Note**: Encryption before upload is a TODO — currently unencrypted JSON.

### `POST /v1/storage/manifest`
Retrieve the backup manifest (what's stored in Supabase for this user).
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ manifest: { id, created_at, documents: [...] } }`

### `POST /v1/storage/restore`
Restore user data from a Supabase backup.
- **Auth**: Bearer token
- **Request**: `{ owner_id, manifest_id }`
- **Response**: `{ restored_count }`
- **Logic**: Fetches manifest → downloads documents → re-indexes via `Seer.put()` → rebuilds HNSW.

### `POST /v1/storage/purge`
Delete all user data (documents, groups, HNSW nodes, Sinatra state, Gita wallet).
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ success: true }`
- **Caution**: Irreversible. Triggers full registry cleanup and graph compaction.

### `POST /v1/storage/documents/purge`
Delete all documents only (preserves groups and Sinatra/Gita state).
- **Auth**: Bearer token
- **Request**: `{ owner_id }`

### `POST /v1/storage/groups/purge`
Delete all groups only.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`

---

## Tools

### `POST /v1/tools/summarize`
Summarize a block of text using the loaded LLM.
- **Auth**: Bearer token
- **Request**: `{ text, max_length? }`
- **Response**: `{ summary: "string" }`
- **Logic**: Single-shot LLM call with summarization prompt template. No RAG retrieval.

---

## Frank (GBT Debug)

Developer endpoints for inspecting Sinatra internals.

### `POST /v1/frank/gbt`
Dump the full GBT model state for the authenticated owner.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: Full `Sinatra.Registry` as JSON — trees, hyperparameters, training data, harmony memories.

### `POST /v1/frank/parking`
Inspect the partition parking pipeline — see what's queued for GBT training.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ parked_partitions: [...], queue_depth: N }`

### `POST /v1/frank/reset`
Wipe all Sinatra state for this owner. Resets GBT model, datasets, harmony memories.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ success: true }`
- **Use Case**: Reset a corrupted or overtrained GBT model.

---

## HNSW Graph Management

### `POST /v1/hnsw/stats`
Get HNSW graph statistics for the authenticated owner.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ global: { node_count, edge_count, levels }, personal: { node_count } }`

### `POST /v1/hnsw/personal`
Inspect the personal HNSW graph (nodes, edges, recency weights).
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: Full personal graph structure.

### `POST /v1/hnsw/global`
Inspect the global HNSW graph.
- **Auth**: Bearer token
- **Response**: Global graph structure (large — paginate for production use).

### `DELETE /v1/hnsw/node`
Delete a specific node from HNSW.
- **Auth**: Bearer token (owner must own the node)
- **Request**: `{ node_id, owner_id }`
- **Response**: `{ success: true }`
- **Logic**: `TableMutator.delete()` removes from graph + `RegistryMutator` removes from registry.

### `POST /v1/atlas`
Get Atlas visualization data — graph topology optimized for rendering.
- **Auth**: Bearer token
- **Request**: `{ owner_id, scope: "global|personal" }`
- **Response**: `{ nodes: [{ id, label, level, position }], edges: [{ from, to, weight }] }`

---

## Marielle Personalization

### `POST /v1/marielle/open`
Generate a recency-weighted opening question for a new session.
- **Auth**: Bearer token
- **Request**: `{ owner_id, conversation_context? }`
- **Response**: `{ question: "string", confidence: 0.87 }`
- **Algorithm**: Sample personal HNSW by recency decay → pick highest-confidence topic cluster → generate question via LLM.

### `POST /v1/marielle/proactive`
Lightweight check: does Marielle have something relevant to add right now?
- **Auth**: Bearer token
- **Request**: `{ owner_id, current_messages: [...] }`
- **Response**: `{ should_interject: bool, score: 0.0–1.0 }`
- **Algorithm**: Compute Jaccard distance between current conversation and personal graph topics. If drift is low (user is on a familiar topic) and topic saturation is high, `should_interject = true`.

### `POST /v1/marielle/interject`
Generate a mid-session lateral question.
- **Auth**: Bearer token
- **Request**: `{ owner_id, current_messages: [...] }`
- **Response**: `{ question: "string", source_partition_id: "uuid", confidence: 0.0–1.0 }`
- **Algorithm**: Embed centroid of conversation → search personal HNSW → score candidates by novelty (low overlap with current messages) → generate question from top candidate.

### `POST /v1/marielle/bridge`
Generate a question that bridges two user profiles.
- **Auth**: Bearer token
- **Request**: `{ owner_id_a, owner_id_b }`
- **Response**: `{ question: "string", shared_topic: "string" }`
- **Algorithm**: Find intersection of two personal HNSW graphs by centroid proximity → pick shared topic → generate bridging question.
- **Requires**: Both owners must have `bridging_enabled` in registry.

---

## Profile

### `POST /v1/profile`
Get the authenticated user's profile.
- **Auth**: Bearer token
- **Request**: `{ owner_id }`
- **Response**: `{ owner_id, groups, document_count, bridging_enabled, created_at }`

### `POST /v1/profile/update`
Update profile settings.
- **Auth**: Bearer token
- **Request**: `{ owner_id, bridging_enabled: bool }`
- **Response**: `{ success: true, profile }`

---

## Wallet & Earnings

### `GET /v1/wallet`
Earnings summary and transaction history for the authenticated owner.
- **Auth**: Bearer token (owner_id inferred from JWT)
- **Response**:
  ```json
  {
    "balance": 142.50,
    "total_earned": 398.00,
    "transactions": [{
      "id": "uuid",
      "type": "royalty|cashout",
      "amount": 12.50,
      "created_at": "ISO8601",
      "inference_id": "uuid"
    }],
    "credit_exchanges": [{
      "inference_id": "uuid",
      "credits_earned": 5.2,
      "contributions": [{ "owner_id": "uuid", "credits": 3.1 }]
    }]
  }
  ```

---

## Oracle P2P

### `GET /oracle/nodes`
View local Oracle node identity and current peer topology (open, no auth).
- **Response**:
  ```json
  {
    "node_id": "uuid",
    "peers": [{
      "id": "uuid",
      "endpoint": "wss://...",
      "state": "connected|disconnected",
      "trust_score": 0.85,
      "knowledge_domains": ["topic1", "topic2"]
    }],
    "edge_count": 4,
    "dag_depth": 2
  }
  ```

### `POST /oracle/peers`
Connect to a new peer node at runtime (protected, admin-equivalent).
- **Auth**: Bearer token (admin)
- **Request**: `{ endpoint: "wss://peer-host:port" }`
- **Response**: `{ success: true, peer_id: "uuid" }`
- **Logic**: Opens WebSocket to endpoint, performs handshake, adds to DAG with initial trust score.

---

## Admin Routes (AdminMiddleware — Privileged)

All require Bearer token from a known admin owner_id.

### `POST /v1/admin/list/owners`
List all registered owner IDs in the system.
- **Response**: `{ owners: ["uuid", ...] }`

### `POST /v1/admin/list/documents`
List documents for a target owner.
- **Request**: `{ owner_id }`
- **Response**: Same shape as `/v1/list/documents`

### `POST /v1/admin/list/groups`
List groups for a target owner.

### `POST /v1/admin/modify`
Modify any document (bypass ownership check).
- **Request**: Same as `/v1/modify` but `owner_id` is the target owner, not the admin.

### `POST /v1/admin/modify/group`
Modify any group.

### `POST /v1/admin/hnsw/stats`
HNSW stats for a specific owner.
- **Request**: `{ owner_id }`

### `POST /v1/admin/hnsw/personal`
Personal HNSW graph for any owner.
- **Request**: `{ owner_id }`

### `DELETE /v1/admin/hnsw/node`
Delete any HNSW node regardless of ownership.

### `POST /v1/admin/hnsw/compact`
Compact all HNSW graphs — remove deleted/orphaned nodes and rebuild edge lists. CPU-intensive.
- **Use Case**: Run as a cron job (e.g., nightly via admin automation).
- **Response**: `{ compacted_nodes: N, elapsed_ms: N }`

### `POST /v1/admin/hnsw/personal/rebuild`
Rebuild empty personal HNSW graphs for all owners who have documents but no personal graph.
- **Phase**: Phase 3 migration target — after initial deployment of personal HNSW feature.

### `POST /v1/admin/sinatra/gbt`
Full Sinatra GBT state for any owner.
- **Request**: `{ owner_id }`

### `POST /v1/admin/table/document`
PartitionIndex + PQ stats for a document.
- **Request**: `{ document_id }`
- **Response**: `{ partition_count, codebook_size, compression_ratio, avg_cosine_error }`

### `POST /v1/admin/system/stats`
Aggregate system statistics across all owners.
- **Response**: `{ total_owners, total_documents, total_partitions, total_nodes, memory_usage_mb, uptime_seconds }`

### `POST /v1/admin/owner/delete`
Delete an owner and ALL associated data (documents, groups, HNSW nodes, Sinatra state, Gita wallet).
- **Request**: `{ owner_id }`
- **Response**: `{ success: true, deleted: { documents, partitions, nodes } }`
- **Caution**: Irreversible.

### `POST /v1/admin/audit/stale`
Scan for stale documents — entries in the registry with no corresponding HNSW node or partition data.
- **Response**: `{ stale_documents: [{ id, owner_id, reason }] }`

### `POST /v1/admin/audit/reconcile`
Remove stale entries found by the audit scan.
- **Request**: `{ document_ids: ["uuid", ...] }` (from audit results)
- **Response**: `{ removed_count: N }`

---

## Other

### `POST /v1/forms/feedback`
Submit user feedback.
- **Auth**: Bearer token
- **Request**: `{ owner_id, message, rating: 1–5, context? }`
- **Response**: `{ success: true }`
- **Logic**: Persists to `FilePersistence` under `feedback/` directory.

### `POST /v1/speak`
Text-to-speech proxy via Mistral TTS API.
- **Auth**: Bearer token
- **Request**: `{ text, voice? }`
- **Response**: Audio stream (binary)
- **Logic**: Forwards to Mistral TTS endpoint, streams audio back.
