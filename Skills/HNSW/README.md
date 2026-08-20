# HNSW — Graph Proxy Layer

> HNSW graphs no longer live in Seer. All HNSW data (nodes, vectors, codebooks) is owned and managed by **Totem nodes**. Seer's role is to proxy HNSW requests to the appropriate Totem node via gRPC.

For the HNSW implementation itself, see [Totem/README.md](../Totem/README.md) or the Totem repository.

---

## Seer's HNSW Role

[HNSW.swift](../../Sources/API/Routes/HNSW.swift) registers all `/v1/hnsw/*` routes as thin gRPC adapters:

**Stats routes** — fan out to **all** active Totem nodes, aggregate results:
- `POST /v1/hnsw/stats` — sum live nodes across nodes, max level
- `POST /v1/hnsw/document/stats` — same, filtered to one document

**Graph routes** — proxy to a **specific** Totem node via `seer.totem_ids[0]`:
- `POST /v1/hnsw/personal` — personal graph (scope: personal)
- `POST /v1/hnsw/personal/hubs` — hub-only personal graph
- `POST /v1/hnsw/personal/document` — personal graph for one document
- `POST /v1/hnsw/personal/documents` — personal graph for a set of documents
- `POST /v1/hnsw/global` — global graph
- `POST /v1/hnsw/global/hubs` — hub-only global graph
- `POST /v1/hnsw/documents` — global graph for a set of documents
- `POST /v1/hnsw/documents/hubs` — hub-only global graph for a document set
- `POST /v1/hnsw/node` — single node inspection
- `POST /v1/hnsw/nodes/batch` — batch node fetch
- `DELETE /v1/hnsw/node` — soft-delete a node

---

## Routing Helpers

```swift
// Resolve the target Totem node from seer.totem_ids[0]
private func targetNode(_ seerRequest: SeerRequest, seer: Seer) async throws -> (TotemQueryClient, TotemNode)

// Fan out stats to ALL active Totem nodes
private func fanoutStats(seer: Seer, statReq: Totem_V1_TotemHNSWStatsRequest) async throws -> HNSWStatsResponse
```

`targetNode` throws `400 Bad Request` if `totem_ids` is missing or the UUID doesn't match a registered node. Always include `totem_ids` in graph route requests.

---

## Admin HNSW Routes

All admin HNSW routes (`/v1/admin/hnsw/*`) return `503 Service Unavailable` with reason "HNSW is managed by Totem nodes". Compact, dedup, and rebuild operations must be triggered directly on Totem nodes via their HTTP API.

---

## Adding an HNSW Feature

1. Add the RPC to the Totem proto (`Totem_V1_TotemHNSWService`) in the shared proto file.
2. Implement it in Totem's `TotemHNSWServiceImpl`.
3. Add the gRPC call to `TotemQueryClient` in Seer's `Sources/GRPC/`.
4. Register the route in `HNSW.swift` using `targetNode()` or `fanoutStats()`.
