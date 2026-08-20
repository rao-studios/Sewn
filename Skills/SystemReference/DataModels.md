# Data Models Reference

All major types across Seer, Sinatra, Gita, and Oracle. Use this as a quick lookup when writing request/response handlers, tests, or new features.

---

## Seer (Database)

### `Seer.Document`
Document-level metadata. One document = one source URL (a webpage, file, etc.).
```swift
struct Document {
    let id: String          // UUID
    let url: String         // Source URL
    let owner_id: String    // Owner UUID
    let created_at: Date
}
```

### `Seer.Partition`
A chunk of a document with its embedding. One document → N partitions.
```swift
struct Partition {
    let id: String                        // UUID
    let documentId: String
    let ownerId: String
    let url: URL                          // source URL
    var embedding: [Float]                // full-precision vector (1024-dim); cleared after PQ train
    var compressedEmbedding: [UInt16]?    // PQ codes (16 × UInt16 = 32 bytes)
    let mediaType: MediaType              // .text | .image
    let text: String                      // raw chunk text (cleared after PartitionData written)
    let hint: String                      // server-generated key phrases embedded alongside text
}
```

### `PartitionSlot`
Lean in-memory record inside `PartitionIndex.slots`. Holds only identifiers and compressed codes — no text or URL (those live in `PartitionData` on disk).
```swift
struct PartitionSlot: Codable {
    var id: String
    var documentId: String
    var compressedEmbedding: [UInt16]?
}
// Reconstructed on demand:
func toPartition(metadata: PartitionData?) -> Seer.Partition
```

### `PartitionData` / `PartitionDataLoader`
Full content record for one partition, stored per-document in `documents/{id}-parts`. Loaded on demand during search result resolution; never held in the in-memory indices.
```swift
struct PartitionData: Codable {
    var id: String
    var url: URL
    var mediaType: MediaType    // .text | .image
    var data: String            // full text or base64 image
    var hint: String
    var ownerId: String
}

typealias PartitionDataLoader = (DocumentID, String) -> PartitionData?
```

### `GlobalPartitionTable`
Wraps `HNSWGraph` and owns the two-tier global search pipeline. Stored as `PartitionTable.shard`. Transparent `Codable` — encodes/decodes as plain `HNSWGraph` (zero migration).
```swift
struct GlobalPartitionTable: Codable {
    var graph: HNSWGraph    // underlying proximity graph
    // + all HNSWGraph properties forwarded
}
// Two-tier search entry point:
mutating func search(
    queryEmbedding: [Float], queryTagEmbedding: [Float]?,
    k: Int, groupFilter: Set<DocumentID>?,
    indices: [DocumentID: PartitionIndex],
    sinatra: Sinatra, ...
) -> (partitions: [(partition: Seer.Partition, distance: Float)],
      trace: HNSWGraph.SearchTrace)
```

### `Seer.Group`
A named collection of documents with shared access control.
```swift
struct Group {
    let id: String
    let label: String
    let owner_id: String
    var documents: [String]     // Document IDs
    var access: SeerRegistry.Access
    var total_earnings: Double  // Gita-tracked earnings
}
```

### `Seer.User`
Thin wrapper around a user's groups. Returned from profile endpoints.
```swift
struct User {
    let owner_id: String
    var groups: [Group]
}
```

### `Seer.DocumentStats`
Engagement tracking per document.
```swift
struct DocumentStats {
    let document_id: String
    var view_count: Int
    var total_earned: Double
    var last_accessed: Date?
}
```

### `SeerRegistry`
In-memory index — the primary access control and ownership lookup structure. Persisted to disk as JSON.
```swift
struct SeerRegistry {
    var owners_documents: [Owner: Set<String>]   // owner → document IDs
    var document_owners: [String: Owner]          // document ID → owner
    var document_groups: [String: Set<String>]    // document ID → group IDs
    var owners_groups: [Owner: Set<String>]       // owner → group IDs
    var group_owners: [String: Owner]             // group ID → owner
    var groups: [String: Group]                   // group ID → Group
    var document_access: [String: Access]         // document ID → access level
    var group_access: [String: Access]            // group ID → access level
    var available_document_ids: Set<String>       // fast lookup for available docs
    var bridging_enabled_owners: Set<Owner>       // owners with bridging on
    var document_stats: [String: DocumentStats]   // document ID → stats
}

enum Access {
    case available    // searchable by all
    case restricted   // searchable by owner only
    case unknown      // treat as restricted
}

struct Owner: Hashable {
    let id: String
}
```

### `Seer.SearchResult`
One result from a vector search.
```swift
struct SearchResult {
    let partition_id: String
    let document_id: String
    let owner_id: String
    let text: String
    let score: Float        // cosine similarity 0.0–1.0
    let isPeer: Bool        // from Oracle peer (not local)
}
```

### `Seer.Wearable`
Lightweight context object passed between Seer operations (carries owner_id, tone, request metadata).
```swift
struct Wearable {
    let owner_id: String
    var tone: Sinatra.Tone?
    var request_id: String
}
```

---

## Sinatra (Sentiment / GBT)

### `Sinatra.Sentiment`
Classification of a single text segment.
```swift
enum Sentiment: String, Codable {
    case positive
    case negative
    case neutral
}

struct SentimentResult {
    let sentiment: Sentiment
    let confidence: Double   // 0.0–1.0
}
```

### `Sinatra.Sentiment.Weight`
How much a specific partition contributed to the overall sentiment score.
```swift
struct Weight {
    let partition_id: String
    let sentiment: Sentiment
    let magnitude: Double    // contribution weight
}
```

### `Sinatra.Tone`
The LLM parameter adjustments output by the GBT model.
```swift
struct Tone {
    var temperature: Double        // 0.0–2.0
    var top_p: Double              // 0.0–1.0
    var repetition_penalty: Double // 1.0–1.5 typical
}
```

**Defaults** (from `GenerationDefaults.swift`): temperature=0.7, top_p=0.9, repetition_penalty=1.0

**Sinatra adjustment logic**: If sentiment score > threshold (e.g. very negative), lower temperature (more deterministic, stable) and raise repetition_penalty. If strongly positive/creative, raise temperature and top_p.

### `Sinatra.Inference`
Full output of one GBT inference run.
```swift
struct Inference {
    let score: Double       // aggregate sentiment score (signed: positive=high)
    let tone: Tone          // resulting LLM parameter adjustments
    let weights: [Sinatra.Sentiment.Weight]  // per-partition contributions
}
```

### `Sinatra.TrainingData`
One collected training sample (interaction signal for GBT retraining).
```swift
struct TrainingData {
    let partition_id: String
    let window_size: Int        // context window at time of retrieval
    let recency_score: Double   // how recent was this partition
    let sentiment_label: Sentiment
    let retrieval_rank: Int     // position in search results
    let timestamp: Date
}
```

### `Sinatra.Trajectory`
Time-series prediction output (sentiment trend over recent interactions).
```swift
struct Trajectory {
    let timestamps: [Date]
    let scores: [Double]
    let predicted_next: Double
    let trend: String    // "improving" | "declining" | "stable"
}
```

### `Sinatra.Registry`
Per-owner Sinatra state. Persisted to disk.
```swift
struct Registry {
    var models: [String: GBTModel]              // owner_id → GBT model
    var datasets: [String: [TrainingData]]       // owner_id → training samples
    var harmony_memories: [String: HarmonyMemory] // owner_id → IMBHS state
    var parked_partitions: [String: [String]]   // owner_id → partition IDs queued for training
    var adjustments: [String: [Adjustment]]     // owner_id → recent tone adjustment history
}
```

### `HarmonyMemory` (IMBHS — Iterated Memory-Based Harmony Search)
Stores sentiment harmonies from past conversations. Used to detect sentiment patterns and initialize GBT training.
```swift
struct HarmonyMemory {
    var harmonies: [[Double]]      // population of parameter vectors
    var scores: [Double]           // fitness scores per harmony
    var memory_size: Int           // max harmonies to retain
    var iteration: Int             // current training iteration
}
```

### `TechnicalIndicators`
Signal processing on sentiment time-series. Produces input features for GBT.
```swift
// All computed from Sinatra.TrainingData score arrays:
EMA(period: 5)       // Exponential Moving Average — tracks short-term sentiment
SMA(period: 20)      // Simple Moving Average — baseline
MACD                 // EMA(12) - EMA(26) — momentum divergence
StochasticK         // (current - min) / (max - min) — relative position
StochasticD         // SMA(3) of K — smoothed
Momentum(period: 10) // current - value N periods ago
```

---

## Gita (Royalty / Wallet)

### `Gita.Payload`
Describes one LLM inference — input to royalty calculation.
```swift
struct Payload {
    let inference_id: String
    let owner_id: String             // requesting user
    let partitions: [PartitionRef]   // partitions that contributed to context
    let peer_results: [OraclePartitionResult]  // from Oracle peers (if any)
    let token_count: Int             // tokens generated (for billing)
    let timestamp: Date
}

struct PartitionRef {
    let partition_id: String
    let document_id: String
    let owner_id: String
    let score: Float                 // similarity score (used for weighting)
}
```

### `Gita.Contribution`
Credit allocated to one owner for one inference.
```swift
struct Contribution {
    let owner_id: String
    let credits: Double
    let partition_ids: [String]      // which of their partitions contributed
}
```

### `Gita.Result`
Full royalty calculation output for one inference.
```swift
struct Result {
    let inference_id: String
    let contributions: [Contribution]   // per-owner credit allocations
    let service_charge: Double          // platform fee
    let total_credits: Double           // sum of all contributions
}
```

### `Gita.Registry` (Market Registry)
Tracks documents and partitions as market "securities."
```swift
struct Registry {
    var document_records: [String: DocumentRecord]    // document_id → record
    var partition_records: [String: PartitionRecord]  // partition_id → record
}

struct DocumentRecord {
    let document_id: String
    let owner_id: String
    var market_weight: Double       // relative market cap (updated after each inference)
    var performance_score: Double   // 0.0–1.0 rolling performance
    var total_earned: Double        // all-time credits earned
    var inference_count: Int
}

struct PartitionRecord {
    let partition_id: String
    let document_id: String
    var share_count: Int            // how many times this partition was retrieved
    var total_earned: Double
}
```

### `Gita.WalletRegistry`
All owner wallets. Persisted to disk.
```swift
struct WalletRegistry {
    var wallets: [String: Wallet]           // owner_id → wallet
    var credit_exchanges: [String: [CreditExchange]]  // owner_id → exchanges
}

struct Wallet {
    let owner_id: String
    var balance: Double
    var total_earned: Double
    var transactions: [Transaction]
}

struct Transaction {
    let id: String
    let type: TransactionType       // .royalty | .cashout | .serviceCharge
    let amount: Double
    let created_at: Date
    let inference_id: String?
}
```

### `Gita.CreditExchange`
Records one inference-to-credit conversion event.
```swift
struct CreditExchange {
    let inference_id: String
    let owner_id: String
    let credits_earned: Double
    let contributions: [Contribution]
    let timestamp: Date
}
```

### `Gita.TokenLedger`
Tracks token consumption per inference (for future billing/metering).
```swift
struct TokenLedger {
    let inference_id: String
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
    let model: String
}
```

### `Gita.ServiceCharge`
Platform fee deducted per inference.
```swift
struct ServiceCharge {
    let inference_id: String
    let amount: Double
    let rate: Double        // e.g. 0.05 = 5% of total credits
}
```

---

## Oracle (P2P Mesh)

### `OracleNode`
Represents a peer in the P2P network.
```swift
struct OracleNode {
    let id: String              // stable UUID (from NodeIdentity)
    let endpoint: String        // wss://host:port
    var state: NodeState        // .connected | .disconnected | .unknown
    var trust_score: Double     // 0.0–1.0 (updated via interaction history)
    var knowledge_domains: [String]   // topic tags for selective fan-out
    var parent_ids: [String]    // DAG parent nodes
    var child_ids: [String]     // DAG child nodes
    var success_count: Int      // successful query responses
    var failure_count: Int      // failed/timeout responses
}
```

### `OracleEdge`
A directed edge in the DAG.
```swift
struct OracleEdge {
    let from: String            // source node ID
    let to: String              // target node ID
    var weight: Double          // trust-weighted routing weight
    let established: Date
    var data_flow_count: Int    // number of queries routed over this edge
}
```

### `OracleQueryRequest`
Distributed search request propagated through the mesh.
```swift
struct OracleQueryRequest {
    let query_id: String
    let embedding: [Float]      // query vector
    let owner_id: String
    let scope: SearchScope      // .global | .personal | .group
    let hop_limit: Int          // max 3 hops (default)
    var visited_nodes: [String] // prevents cycles
    let top_k: Int
    let threshold: Float
}
```

### `OracleQueryResponse`
Response from a peer node.
```swift
struct OracleQueryResponse {
    let query_id: String
    let node_id: String
    let results: [OraclePartitionResult]
}
```

### `OraclePartitionResult`
One search result from a peer.
```swift
struct OraclePartitionResult {
    let partition_id: String
    let document_id: String
    let owner_id: String
    let text: String
    let score: Float
    let source_node_id: String  // which peer returned this
    let hop_count: Int
}
```

### `OracleEvent`
Gossip event propagated through the mesh.
```swift
enum OracleEvent {
    case registryUpdate(owner_id: String, document_count: Int)
    case nodeJoined(node_id: String, endpoint: String)
    case nodeLeft(node_id: String)
    case trustUpdate(node_id: String, new_score: Double)
}
```

### `OracleSnapshot`
Point-in-time topology snapshot.
```swift
struct OracleSnapshot {
    let captured_at: Date
    let local_node_id: String
    let nodes: [OracleNode]
    let edges: [OracleEdge]
    let dag_depth: Int
    let total_queries_handled: Int
}
```

---

## API Request/Response Models (Selected)

### Chat Request (`ChatCompletionRequest`)
```swift
struct ChatCompletionRequest: Content {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool?
    let temperature: Double?
    let top_p: Double?
    let max_tokens: Int?
    let repetition_penalty: Double?
}

struct ChatMessage {
    let role: String        // "user" | "assistant" | "system"
    let content: String
}
```

### Chat Response (`ChatCompletionResponse`)
```swift
struct ChatCompletionResponse: Content {
    let id: String
    let object: String      // "chat.completion"
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage?
}

struct Choice {
    let index: Int
    let message: ChatMessage
    let finish_reason: String?
}
```

### Embedding Request
```swift
struct EmbeddingRequest: Content {
    let input: String
    let model: String?
    let document_id: String?
    let url: String?
    let owner_id: String
}
```

### Search Request
```swift
struct SearchRequest: Content {
    let query: String
    let owner_id: String
    let scope: String       // "global" | "personal" | "group"
    let group_id: String?
    let top_k: Int?
    let threshold: Float?
}
```

### Wallet Response
```swift
struct WalletResponse: Content {
    let owner_id: String
    let balance: Double
    let total_earned: Double
    let transactions: [Gita.Transaction]
    let credit_exchanges: [Gita.CreditExchange]
    let non_self_earnings: Double   // earnings from other users' queries
}
```
