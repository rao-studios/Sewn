# PartitionTable — Moved to Thread

> `PartitionTable`, `PartitionIndex`, `PartitionQuantizer`, `PartitionSlot`, and all related mutators (`TableMutator`, `HNSWTopologyWAL`) no longer live in Sewn. They were migrated to the [Thread](https://github.com/riteshpakala/Totem) repository as part of the distributed architecture rewrite.

Sewn no longer holds any partition data or PQ codebooks. All search, index, and remove operations fan out to Thread nodes over gRPC — see [Thread/README.md](../Thread/README.md).

---

## What Was Here

- **PartitionTable** — multi-shard index: global HNSW + per-document PQ codebooks
- **PartitionIndex** — per-document index: `PartitionQuantizer` (PQ codebooks) + `PartitionSlot` lean records
- **PartitionQuantizer** — product quantization: trains codebooks, encodes vectors (ADC)
- **Three search paths** — global HNSW → personal HNSW → per-document PQ linear scan
- **TableMutator** — actor serializing writes to PartitionTable + HNSWTopologyWAL

All of this is now in `Thread/Sources/Database/PartitionTable/`.

---

## Sewn's Current Role

Sewn's `Sewn+ThreadFanout.swift` provides:

```swift
fanoutSearch(query:embedding:request:)      // → merged, re-ranked results from all Thread nodes
fanoutIndex(partitions:request:)            // → index across all Thread nodes
fanoutRemove(documentId:ownerId:)           // → soft-delete across all Thread nodes
fanoutLibrary(ownerId:page:)                // → paginated document library
fanoutDocumentMetadata(partitionId:)        // → document-level metadata from one node
fanoutDocumentNodes(documentId:ownerId:)    // → HNSW nodes for a document (admin inspection)
```
