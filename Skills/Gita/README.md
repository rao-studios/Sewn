# Gita — Royalty, Wallet & Economic System

Gita tracks how each document contributes to LLM inferences and distributes royalty credits to document owners. It uses a market metaphor: documents are "securities," partitions are "shares," inferences are "trades," and royalties are "dividends."

---

## Market Metaphor

| Market Term | Sewn Equivalent | Meaning |
|-------------|-----------------|---------|
| Security | `Sewn.Document` | A tradeable asset (contributes to inferences) |
| Share | `Sewn.Partition` | A unit of value within a document |
| Trade | LLM Inference | An event that consumes document knowledge |
| Dividend | Royalty credit | Payment to document owners after a trade |
| Market cap | `DocumentRecord.market_weight` | Relative contribution weight across all owners |
| Performance | `DocumentRecord.performance_score` | Rolling quality score (relevance × retrieval rank) |

This metaphor makes the royalty math intuitive and sets up natural extensions for future P2P settlement and token-based exchange.

---

## Components

```
Gita (actor)
  ├── Gita.Registry            — market registry (documents as securities)
  ├── Gita.WalletRegistry      — all owner wallets + transaction history
  ├── Gita+Royalty.swift       — royalty calculation logic
  ├── Gita+StreamBilling.swift — streaming response billing
  ├── Gita+Spans.swift         — token span tracking
  └── Wallet/
      ├── Gita.CreditExchange  — inference → credit conversion records
      └── Gita.WalletRegistry  — wallet state management
```

Source: `Sources/Gita/`

---

## Royalty Calculation (`Gita+Royalty.swift`)

### Input: `Gita.Payload`
```swift
struct Payload {
    let inference_id: String
    let owner_id: String             // who's asking
    let partitions: [PartitionRef]   // retrieved local partitions + their scores
    let peer_results: [OraclePartitionResult]  // from Oracle peers (future: billable)
    let token_count: Int             // tokens generated
}
```

### Step 1: Score each partition's contribution
Each partition gets a raw weight based on its retrieval score (cosine similarity):
```
raw_weight(partition) = score² × market_weight(document)
```

Squaring the score penalizes low-relevance retrievals — a partition with 0.6 similarity contributes far less than one at 0.9.

`market_weight(document)` is from `Gita.Registry.DocumentRecord.market_weight` — a rolling performance weight updated after each inference.

**Known TODO**: Current implementation uses simple magnitude split. A planned enhancement weights by Sinatra's GBT sentiment contribution scores (partitions that drove tone adjustment should earn more).

### Step 2: Group by owner
Sum weights per owner_id:
```
owner_total_weight = Σ raw_weight(partition) for all partitions owned by that owner
```

### Step 3: Service charge
```
service_charge = total_weight × 0.05  (5% platform fee — configurable)
distributable = total_weight - service_charge
```

### Step 4: Normalize to credits
```
credits(owner) = (owner_total_weight / total_weight) × distributable
```

### Step 5: Record & distribute
- Create `Gita.CreditExchange` record
- Add `Gita.Transaction` to each owner's wallet
- Update `DocumentRecord.performance_score` and `market_weight`
- Update `PartitionRecord.share_count`

### Step 6: Non-self earnings
Royalties from OTHER users querying your documents (cross-owner inferences) are tracked separately as `non_self_earnings`. Displayed separately in `GET /v1/wallet`.

---

## Market Weight Updates

After each inference, document market weights are updated using an exponential moving average:
```
new_market_weight = α × inference_contribution + (1-α) × old_market_weight
```
Where `α` = 0.1 (learning rate). This gives recent high performers increasing influence over time.

`performance_score` = harmonic mean of (retrieval rank percentile, similarity score). A document that's always rank 1 at 0.95 similarity will have performance_score ≈ 0.95.

---

## Stream Billing (`Gita+StreamBilling.swift`)

For streaming responses (SSE), token counts aren't known until the stream completes. Stream billing works differently:

1. Start of stream: create pending `Gita.Payload` with `token_count = 0`
2. Track tokens as chunks arrive (via `Gita+Spans.swift`)
3. End of stream: finalize payload with actual token count → run royalty calculation

`Gita.TokenLedger` records prompt tokens + completion tokens per inference. Future billing against API usage will draw from this ledger.

---

## Token Span Tracking (`Gita+Spans.swift`)

Spans track which portions of the generated response were informed by which partitions. This is preparation for fine-grained attribution ("this sentence came from document X").

Currently spans record:
- Token range (start_token, end_token)
- Contributing partition IDs
- Attribution confidence (based on retrieval score)

Spans are stored per-inference and are available via the admin API for debugging. Full span-based royalty (different rates for directly-cited vs context-only partitions) is a future enhancement.

---

## Wallet System

### Wallet structure
```
WalletRegistry {
    wallets: [owner_id: Wallet]
    credit_exchanges: [owner_id: [CreditExchange]]
}

Wallet {
    owner_id: String
    balance: Double         // current spendable balance
    total_earned: Double    // all-time earnings (never decrements)
    transactions: [Transaction]
}
```

### Transaction types
| Type | When | Effect |
|------|------|--------|
| `.royalty` | After each inference that uses owner's documents | Increases `balance` + `total_earned` |
| `.serviceCharge` | Same inference | Platform fee deducted (recorded separately) |
| `.cashout` | Manual cashout (future: Web3 withdrawal) | Decreases `balance` |

### `GET /v1/wallet` response
```json
{
  "balance": 142.50,
  "total_earned": 398.00,
  "non_self_earnings": 89.25,
  "transactions": [...],
  "credit_exchanges": [...]
}
```

`non_self_earnings` = earnings from other users' queries on your documents. This is the key metric for document owners who contribute knowledge to the network.

---

## GitaContract (`GitaContract.swift`)

Stub for the Web3 smart contract interface. Currently not active. Planned for P2P Oracle phase where:
- Royalty credits are settled on-chain
- Document owners receive ERC-20 tokens
- Cashout = on-chain withdrawal

The `Web3.swift` package is already in `Package.swift` dependencies — the scaffolding is in place.

---

## Gita Registry Persistence

- `Gita.Registry` → `~/.sewn/gita/registry`
- `Gita.WalletRegistry` → `~/.sewn/wallet_registry`
- Both serialized as JSON via `PersistenceActor`
- Loaded at startup, written after each mutation

**Caution**: Wallet registry write happens after every inference. With high query volume, this can be a disk I/O bottleneck. Future optimization: batch writes every N inferences.

---

## Royalty for Peer Documents (Future — Oracle Integration)

When Oracle is enabled and peer results are included in an inference, `Gita.Payload.peer_results` contains those results. Currently, peer results are included in context but NOT billed — they don't generate royalty credits because the peer's wallet lives on a remote node.

**Planned**: When P2P Oracle is fully wired, inter-node credit settlement will work via:
1. Requesting node: debit credits to remote peer
2. Remote peer node: receive credit confirmation and credit the document owner's wallet
3. Settlement protocol: batched every N minutes or on threshold

This requires `GitaContract` to be implemented and inter-node trust from Oracle to establish payment channels.

---

## Building a New Feature That Touches Gita

Checklist:
1. **New royalty weight factor** → update `Gita+Royalty.swift` calculation, document the new weight source
2. **New transaction type** → add to `Transaction.type` enum + update `GET /v1/wallet` response
3. **New wallet field** → add to `Gita.Wallet`, update persistence serialization
4. **Span attribution change** → update `Gita+Spans.swift`
5. **Stream billing change** → update `Gita+StreamBilling.swift`
6. **Tests** → `Flow2_GitaCreditTests.swift`, `Flow2_GitaRoyaltyTests.swift`, `Flow2_GitaWalletTests.swift`, `Flow2_GitaSpanTests.swift`

---

## Known TODOs / Design Gaps

- **Weighted Influence**: royalty currently weights by similarity score only. TODO is to use Sinatra GBT contribution scores as additional weight (partitions that drove tone adjustment earn more)
- **Performance scoring**: `Gita.Registry.swift` has a TODO on the `performanceScoring` logic — needs validation against real inference patterns
- **Peer royalty settlement**: `peer_results` in `Gita.Payload` are collected but royalties not distributed cross-node
- **Encryption**: wallet data is stored as plaintext JSON — should be encrypted at rest
- **Cashout flow**: Web3 withdrawal via `GitaContract` is not yet implemented
