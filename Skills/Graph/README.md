# Graph & Stats — The Thread Proxy Routes

> **HNSW graphs no longer live in Sewn, and neither do the routes that exposed
> them.** Every `/v1/hnsw/*` and `/v1/admin/hnsw/*` endpoint is gone. Two narrower
> routes replaced them: `POST /v1/graph` for knowledge-graph queries and
> `GET /v1/stats` for aggregate public counts.

Source: `Sources/API/Routes/Graph.swift`, `Sources/API/Routes/Stats.swift`

---

## `POST /v1/graph` — Knowledge-Graph Query

A knowledge-graph query proxied to the whole Thread fleet: resolve entities by
name and/or free-text similarity, then traverse up to `hops` edges.

### Request

```swift
struct GraphProxyRequest: Codable {
    let sewn: SewnRequest
    let entity: String?            // entity name lookup (token containment)
    let query: String?             // free text; each Thread embeds it locally
    let kinds: [String]?           // restrict matches to these entity kinds
    let hops: Int?                 // traversal depth 0–3, default 1
    let limit: Int?                // max entities per Thread, default 20
    let includeDocuments: Bool?    // "include_documents", default true
}
```

**At least one of `entity` / `query` must be present**, or the route throws
`400 Bad Request: "Provide 'entity' and/or 'query'."`

The two resolution modes are complementary: `entity` is deterministic token
containment, `query` is embedding similarity computed **on each Thread node**.
Supplying both widens the match set.

Note that `limit` is per-Thread, not per-response. A ten-node fleet with
`limit: 20` can return up to 200 entities before deduplication.

### Response

```swift
struct GraphProxyResponse: Codable {
    var object: String = "graph"
    let entities: [GraphProxyEntity]            // id, name, kind, score, mention_count, document_ids
    let relationships: [GraphProxyRelationship] // id, subject_id, predicate, object_id, weight, document_ids
    let documents: [GraphProxyDocument]         // id, name?, owner_id?
    let stats: GraphProxyStats                  // entity_count, relationship_count
}
```

Empty strings from the wire are normalized to `nil` for `documents[].name` and
`documents[].owner_id` — an unnamed document reads as absent rather than as `""`.

### Merge semantics

`fanoutGraph` broadcasts to every active node and merges:

| Collection | Dedupe key | Conflict resolution |
|-----------|-----------|--------------------|
| `entities` | `id` | `mentionCount` **summed**, `score` takes the **max** |
| `relationships` | `id` | `weight` **summed** |
| `documents` | `id` | first wins |
| `stats` | — | **summed** |

The asymmetry is deliberate: mention counts and edge weights are additive
evidence across the fleet, while a similarity score is a measurement and the best
one should win rather than an average that a single weak node could drag down.

---

## `GET /v1/stats` — Public Corpus Counts

```swift
struct StatsResponse: Codable {
    let publicDocumentCount: Int
    let publicGroupCount: Int
}
```

An **open route** — no auth — which is why it is the only route in Sewn with its
own rate limiter.

```swift
private actor StatsRateLimiter {
    private struct Window { var count: Int; var windowStart: Date }
    func allow(ip: String) -> Bool
}
```

Over the limit returns `429 Too Many Requests`.

Client IP resolution, in order:

```swift
request.headers["X-Forwarded-For"]?.split(separator: ",").first?.trimmed
  ?? context.remoteAddress?.ipAddress
  ?? "unknown"
```

The first `X-Forwarded-For` entry wins, because Sewn runs behind a reverse proxy.

Implementation: `fanoutLibrary(ownerId: "")` across the fleet, filtered to groups
with `access == .available`, then counted. The empty owner id is what makes it a
public query. Note this walks the full library — it is not a cheap route, which
is the other reason for the limiter.

---

## `GET /v1/threads` — Fleet Inspection

Open route. The registered node list with `thread_id`, `host`, `grpc_port`,
`http_port`, `last_seen`, `is_active`, `accepting_storage`, plus the mothership
id. First stop when retrieval returns nothing. See `Skills/Thread/README.md`.

---

## The `sewn` Request Object

Every protected route accepts it:

```swift
struct SewnRequest: Codable {
    let ownerId: String              // "owner_id" — OVERWRITTEN by AuthMiddleware
    let group: Sewn.Group?
    let groups: [Sewn.Group]?
    let entities: [String]?
    let tags: [String]?
    let aggregate: Bool?
    let scope: SewnRequestScope?     // .global | .personal
    let threadIds: [String]?         // "thread_ids" — pin to specific nodes
    let personalThreadId: String?    // "personal_thread_id"
    let requestID: String?           // "request_id" — log correlation
}
```

`from(context)` resolves it against the authenticated user:

```swift
guard let userId = context.authUserId else { throw … }
// Normalize to lowercase so registry key lookups are always consistent.
// UUID.uuidString returns uppercase on all Swift platforms, but Supabase
// auth.uid() is always lowercase — without this, ownership checks would
// [mismatch].
```

**Owner ids are lowercased.** This bug class is real enough to have its own test
file, `Flow5_OwnerIdNormalizationTests.swift`. Any new code keying on an owner id
must lowercase it.

`threadIds` is the escape hatch for pinning a request to specific nodes — used by
`fanoutIndex` to choose a target and available on remove and library fan-out.

---

## What the HNSW Routes Did, and Where That Went

| Old route | Now |
|-----------|-----|
| `POST /v1/hnsw/stats`, `/v1/hnsw/document/stats` | Removed. Aggregate counts: `GET /v1/stats`; fleet stats: `fanoutStats()` internally |
| `POST /v1/hnsw/personal{,/hubs,/document,/documents}` | Removed. Per-owner graphs do not exist in Sewn |
| `POST /v1/hnsw/global{,/hubs}`, `/v1/hnsw/documents{,/hubs}` | Removed. `POST /v1/graph` covers knowledge-graph traversal |
| `POST /v1/hnsw/node`, `/v1/hnsw/nodes/batch`, `DELETE /v1/hnsw/node` | Removed. Node inspection is a Thread concern |
| `POST /v1/admin/hnsw/*` (stats, personal, node, compact) | Removed entirely — they used to return 503 |
| `POST /v1/admin/table/document` | Removed |

Compaction, dedup, rebuild, and node-level inspection are triggered on Thread
nodes directly through their own HTTP API. Sewn has no admin surface for them,
and adding one would re-create the coupling the split removed.

---

## Adding a Graph Feature

1. Extend `ThreadGraphQueryRequest` / `Response` in Conduit's `thread.proto`
   with fresh field numbers.
2. Implement the traversal on Thread.
3. Extend `fanoutGraph` in `Sources/Core/Sewn+ThreadFanout.swift`, and decide the
   merge rule for any new collection — additive evidence sums, measurements take
   the max.
4. Extend `GraphProxyRequest` / `GraphProxyResponse`, keeping the snake_case
   `CodingKeys` convention and the empty-string→`nil` normalization.
5. Roll out Conduit → Thread → Sewn.
