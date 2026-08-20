# PartitionTable — Moved to Totem

> `PartitionTable`, `PartitionIndex`, `PartitionQuantizer`, `PartitionSlot`, and all related mutators (`TableMutator`, `HNSWTopologyWAL`) no longer live in Seer. They were migrated to the [Totem](https://github.com/riteshpakala/Totem) repository as part of the distributed architecture rewrite.

Seer no longer holds any partition data or PQ codebooks. All search, index, and remove operations fan out to Totem nodes over gRPC — see [Totem/README.md](../Totem/README.md).

---

## What Was Here

- **PartitionTable** — multi-shard index: global HNSW + per-document PQ codebooks
- **PartitionIndex** — per-document index: `PartitionQuantizer` (PQ codebooks) + `PartitionSlot` lean records
- **PartitionQuantizer** — product quantization: trains codebooks, encodes vectors (ADC)
- **Three search paths** — global HNSW → personal HNSW → per-document PQ linear scan
- **TableMutator** — actor serializing writes to PartitionTable + HNSWTopologyWAL

All of this is now in `Totem/Sources/Database/PartitionTable/`.

---

## Seer's Current Role

Seer's `Seer+TotemFanout.swift` provides:

```swift
fanoutSearch(query:embedding:request:)      // → merged, re-ranked results from all Totem nodes
fanoutIndex(partitions:request:)            // → index across all Totem nodes
fanoutRemove(documentId:ownerId:)           // → soft-delete across all Totem nodes
fanoutLibrary(ownerId:page:)                // → paginated document library
fanoutDocumentMetadata(partitionId:)        // → document-level metadata from one node
fanoutDocumentNodes(documentId:ownerId:)    // → HNSW nodes for a document (admin inspection)
```
