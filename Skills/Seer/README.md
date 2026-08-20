# Seer Database

The Seer database is a custom vector store built in Swift. It combines two search algorithms — HNSW for global approximate nearest neighbor and Product Quantization (PQ) for fine-grained reranking — and manages multi-tenant document ownership, access control, and personalized graphs per owner.

---

## Core Components

```
Seer (actor)
  ├── SeerRegistry                — in-memory ownership & access metadata
  ├── PartitionTable              — global search index (PQ codebooks + HNSW)
  │   ├── shard: GlobalPartitionTable — two-tier global search (tag pre-filter + HNSW)
  │   │   └── graph: HNSWGraph    — underlying proximity graph, all documents
  │   └── indices: [DocumentID: PartitionIndex]  — per-doc PQ codebooks + slots
  ├── Per-Owner HNSW Graphs       — personalized search per user (recency-weighted)
  ├── TableMutator (actor)        — serializes PartitionTable writes
  ├── RegistryMutator (actor)     — serializes registry metadata writes
  └── PersonalHNSWMutator (actor) — serializes per-owner graph writes
```

Source files: `Sources/Database/`

---

## HNSW (Hierarchical Navigable Small World)

### What it is
HNSW is a graph-based approximate nearest neighbor (ANN) algorithm. It builds a multi-layer graph where higher layers are sparse (long-range connections) and lower layers are dense (precise neighbors). Search starts at the top layer and greedily descends.

**Complexity**: O(log N) for search, O(log N) for insertion.

### Two HNSW graphs

**Global graph** (`global_graph`):
- Contains ALL indexed partitions from ALL owners.
- Used for cross-owner search (when access is `.available`).
- Mutations go through `TableMutator` actor.
- Persisted as mmap'd binary via `HNSWVectorStore` + `HNSWTopologyWAL`.

**Personal graphs** (`personal_graphs/{owner_id}`):
- One per owner, contains only that owner's partitions.
- Recency-weighted: recent documents have higher entry priority in search.
- Used for personalized queries and Marielle's context.
- Mutations go through `PersonalHNSWMutator` actor.

### Key parameters

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `M` | 16 | Max edges per node per layer |
| `efConstruction` | 200 | Beam width during insertion |
| `efSearch` | 50 | Beam width during search |
| `maxLevel` | log(N) | Levels computed per-insertion probabilistically |

### Compaction
Deleted nodes leave "tombstone" entries. Compaction (`POST /v1/admin/hnsw/compact`) rebuilds the graph, removing dead nodes and rewiring edges. Run nightly as a cron job. Production recommendation: schedule via `POST /oracle/peers` style admin trigger.

### Write-Ahead Log (WAL)
`HNSWTopologyWAL` is an append-only file of HNSW operations (insert, delete). On crash recovery, Seer replays the WAL to reconstruct the graph without re-embedding all documents. The WAL is truncated after successful compaction.

---

## Product Quantization (PQ)

### What it is
PQ compresses high-dimensional float vectors (e.g. 1024 dims × 4 bytes = 4KB) into short byte codes (e.g. 32 bytes). Search on compressed vectors is ~8× faster with minimal accuracy loss.

### How it works
1. **Training**: cluster the embedding space into sub-quantizers (subvectors × centroids). Each sub-space gets K centroids (usually K=256).
2. **Compression**: encode each vector by finding its nearest centroid in each sub-space → store centroid indices as bytes.
3. **Search**: compute distances in quantized space (lookup tables per sub-quantizer). Asymmetric Distance Computation (ADC) keeps the query uncompressed for better accuracy.

### PartitionTable
`PartitionTable` stores compressed embeddings indexed by document_id → [partitions]. PQ provides per-document codebooks (trained on that document's partition set).

### `GlobalPartitionTable`
Wraps `HNSWGraph` and owns the two-tier global search pipeline. `PartitionTable.shard` is this type. Tier 1 applies a tag pre-filter (document-level) using `queryTagEmbedding`; Tier 2 runs HNSW beam search and resolves raw results to `Seer.Partition` via `PartitionIndex.slots`. See `PartitionTable/README.md` for the full pipeline.

### Adaptive Thresholding
`PartitionQuantizer` maintains an adaptive cosine similarity threshold:
- Initial threshold: static (e.g. 0.75)
- After N searches: adjusts based on score distribution of returned results
- If top results cluster high → raise threshold (reduce noise)
- If top results cluster low → lower threshold (improve recall)
- Key file: `PartitionQuantizer.swift`

---

## Document → Partition Flow

```
PUT document
  │
  ├─ Sentence boundary detection (SentenceBoundary.swift)
  │   └─ Split text into sentence-aligned chunks
  │
  ├─ For each chunk:
  │   ├─ EmbeddingModelProvider.embed() → float32[1024]
  │   ├─ PartitionQuantizer.compress() → UInt8[32] (PQ encoding)
  │   ├─ TableMutator.insert(node)       → global HNSW
  │   ├─ PersonalHNSWMutator.insert()    → personal HNSW
  │   └─ PartitionTable.store(partition) → per-document PQ index
  │
  └─ RegistryMutator.register(document) → SeerRegistry update
```

**Why sentence boundaries?** Embedding models have context length limits. Splitting on sentence boundaries (rather than arbitrary character windows) keeps semantic units intact and reduces information loss at chunk edges.

---

## Search Flow (Full Detail)

```
Seer.search(query, owner_id, scope)
  │
  ├─ 1. Embed query → float32[1024]
  │
  ├─ 2. Query Expansion (Seer+QueryExpander.swift)
  │   ├─ Generate N paraphrase variants via LLM (low temperature)
  │   ├─ Generate M keyword expansion variants
  │   └─ Union of all candidate sets
  │
  ├─ 3. HNSW traversal (per query variant)
  │   ├─ Scope = global: search global HNSW graph
  │   ├─ Scope = personal: search owner's personal HNSW
  │   └─ Scope = group: search within group's document IDs
  │   └─ Returns top-efSearch candidates per variant
  │
  ├─ 4. PQ Reranking
  │   ├─ For each candidate: compute ADC score vs query
  │   └─ Resort candidates by reranked score
  │
  ├─ 5. Access Control Filter (SeerRegistry)
  │   ├─ Check document_access[partition.document_id]
  │   └─ Drop .restricted entries the requesting owner doesn't own
  │
  ├─ 6. Oracle Fan-out (if enabled, Seer+Peer.swift)
  │   ├─ Send OracleQueryRequest to trust-weighted peers
  │   ├─ Collect OracleQueryResponse (with hop limit)
  │   └─ Merge peer results with local results (deduplicate by partition_id)
  │
  └─ 7. Return top-K above threshold
```

---

## Registry & Access Control

`SeerRegistry` is the in-memory ownership and access metadata index. It's the source of truth for:
- Who owns what document
- Which documents belong to which groups
- What access level each document/group has
- Which owners have bridging enabled

### Lookup patterns
```swift
// Is this document visible to this owner?
func isAccessible(documentId: String, by owner: Owner) -> Bool {
    switch document_access[documentId] ?? .unknown {
    case .available: return true
    case .restricted: return document_owners[documentId] == owner
    case .unknown: return false
    }
}
```

### Mutations always go through RegistryMutator
Direct mutation of `SeerRegistry` outside of `RegistryMutator` is not safe — the actor serializes all writes. Never call `seer.registry.owners_documents[x] = y` directly.

---

## Auto-Memory (`Seer+AutoMemory.swift`)

If an owner has auto-memory enabled, every query they make is also indexed into their personal HNSW graph. This creates a memory of what topics they've explored, used by Marielle for personalization.

- Indexed with a special `document_id` = `"__auto_memory_{owner_id}"`
- Not visible in document listings (filtered out)
- Compacted separately from normal documents

---

## Personal HNSW & Marielle Candidates (`Seer+Marielle.swift`)

Personal graphs use recency weighting: entry points for search are biased toward recently-inserted nodes. This means recent interactions naturally score higher in personalized search.

`Seer+Marielle.swift` provides:
- `getRecentCandidates(owner_id:)` — top-N recent nodes for Marielle's opening question
- `getMarielleInterjectionCandidates(owner_id:, context:)` — scored candidates for mid-session interjection
- `getBridgeCandidates(ownerA:, ownerB:)` — intersection of two personal graphs for bridge questions

---

## Orphan & Stale Document Cleanup

`POST /v1/admin/audit/stale` scans the registry for:
1. Documents in registry with no HNSW nodes (embedding was never inserted or got lost)
2. Documents in registry with no PartitionTable entries
3. PartitionTable entries with no registry record

`POST /v1/admin/audit/reconcile` removes the found stale entries.

**Recommend**: Run audit weekly and reconcile immediately after.

---

## Migration (`Seer+Migration.swift`)

Contains utilities for migrating data between schema versions. Key scenarios:
- Adding personal HNSW graphs to existing owners who only have global entries
- Migrating from old partition format (no compressed_embedding) to new (with PQ)
- Normalizing owner_id casing (historical: some stored as uppercase UUIDs)

`POST /v1/admin/hnsw/personal/rebuild` is the Phase 3 migration route — rebuilds empty personal HNSW graphs for owners who have documents but no personal graph.

---

## IndexQueue (`Utilities/IndexQueue.swift`)

A FIFO actor-based write serializer. Wraps the sequence: embed → insert HNSW → update registry, ensuring that concurrent HTTP requests don't interleave their HNSW writes.

**Why**: HNSW graph insertion walks the graph to find insertion neighbors. If two insertions run concurrently (before the graph is in a consistent state from the first), results are undefined. `IndexQueue` forces sequential execution of the full embed→insert cycle.

This is labeled as a temporary workaround in source comments — the long-term fix is to make HNSW insertion fully actor-safe (or switch to a lock-free structure).

---

## Building a New Feature That Touches Seer

Checklist:
1. **New mutation** → add method to `Seer.swift`, route writes through appropriate mutator actor
2. **New search variant** → extend `Seer+Search.swift`, make sure access control filter is applied
3. **New registry field** → add to `SeerRegistry` struct + update `PersistenceActor` serialization
4. **New admin operation** → add route to `Admin.swift`, apply `AdminMiddleware`
5. **New document metadata** → update `Seer.Document` and `Seer.DocumentStats`
6. **Test coverage** → add to appropriate `Flow*Tests.swift` file (see `TestMaintenance` skill)
