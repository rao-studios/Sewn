# Sinatra — Sentiment, GBT & the Resonance Loop

Sinatra decides **how** to answer. A per-owner Gradient Boosted Trees model
scores each turn's sentiment and engagement, adjusts retrieval distances, and
tunes the next turn's generation parameters. An IMBHS harmony search tunes the
model's own feature windows underneath that.

It is the only part of Sewn that learns online, and it is **gated twice** so
thin or ambiguous turns teach it nothing.

Source: `Sources/Sinatra/`

---

## The Loop, End to End

```
New turn arrives (last user + assistant pair)
    │
    ├─ User reply ≥ 4 words?                     ← Sinatra.sentimentContextLimit
    │     NO  → clear parked entries, skip sentiment AND training
    │     YES ↓
    │
    ├─ Extract RESONANCE (LLM): which passage did the user respond to?
    │     ├─ confidence ≥ 0.55                   ← resonanceConfidenceThreshold
    │     └─ excerpt must be a VERBATIM substring of the assistant response
    │                                              (hallucination guard)
    │
    ├─ Resonance detected?
    │     NO, nothing parked  → nothing to do
    │     NO, data parked     → DROP parked entries, training suppressed
    │     YES, nothing parked → store resonance only (the onboarding path)
    │     YES, data parked    ↓
    │
    ├─ Score SENTIMENT — forced structured tool call (`record_sentiment`)
    │
    ├─ Pace score: reply latency vs assistant length (~3 words/sec baseline)
    ├─ Engagement composite = 0.4 × pace + 0.6 × attentiveness
    ├─ Session boundary? pace < 0.1 AND attentiveness == 0.0
    │     └─ also an auto-memory `.topicChange` trigger
    │
    ├─ Train per-owner GBT + harmony memory (IMBHS)
    │
    └─ Adjustments → SinatraTone for the NEXT turn
         (PQ distance threshold, temperature, top-p, repetition penalty)

Retrieved partitions are PARKED, not trained on — the label is the user's
next reply, which has not happened yet. The loop closes one turn later.
```

`Sinatra.prepare(_:request:modelProvider:provider:)` runs the whole thing and
returns `PrepareResult`.

---

## PrepareResult

`Sources/Sinatra/Sinatra+PrepareResult.swift`

```swift
struct PrepareResult {
    let ledger: Gita.TokenLedger                          // tokens from Sinatra's OWN LLM calls
    let documentStatsUpdates: [DocumentID: Sewn.DocumentStats]
    let resonancePartition: Sinatra.ResonancePartition?    // non-nil ⇒ the training gate passed
    static var empty: PrepareResult
}
```

Three things to know:

- `ledger` is empty on every early-exit path, because no LLM was invoked. Gita
  still prices the turn against it, so Sinatra's cost is billed to the same turn
  that incurred it.
- `documentStatsUpdates` is applied by the **caller**
  (`RegistryMutator.accumulatePerformance`), not by Sinatra. Sinatra has no
  registry dependency by design.
- A non-nil `resonancePartition` is the signal that the GBT + IMBHS training gate
  passed for this cycle. The caller stores it via `BatchPutItem` +
  `Sewn.enqueuePut`.

---

## Resonance Extraction

`Sources/Sinatra/Sinatra+Resonance.swift`

```swift
static let resonanceGroupLabel = "Resonance"
static let resonanceConfidenceThreshold: Double = 0.55

struct ResonancePartition {
    let documentId: String        // SHA-256 + numeric-string, same as Sewn.computeNumericHash
    let text: String              // exact verbatim excerpt
    let embeddingData: [EmbeddingData]
}
```

The LLM returns `ResonanceOutput { detected, excerpt, confidence }`. Extraction
returns `(nil, ledger)` — a clean miss — when any of these hold:

1. `detected == false`, or `confidence < 0.55`.
2. The excerpt is **not a verbatim substring** of the assistant response. This is
   the hallucination guard: a model paraphrasing or normalizing whitespace is
   treated as having found nothing.
3. The embedding call fails.

Resonance documents land in the owner's `"Resonance"` group, so future retrievals
can surface passages the user has already engaged with.

---

## Sentiment Scoring

`Sources/Sinatra/Sinatra+Sentiment.swift`

Sentiment is a **forced structured tool call**, not a lexicon. The field
constraints live in `Sinatra.sentimentSchema` (a JSON Schema) rather than in a
wall of prompt rules:

| Field | Constraint |
|-------|-----------|
| `sentiment` | one of `positive`, `negative`, `neutral`, `mixed`, `ambiguous` |
| `emotional_tones` | 1–4 from a 25-value enum (`angry` … `grateful`, `receptive`, `other`) |
| `reaction_types` | 1–4 from an 18-value enum (`agreement` … `testing`, `other`) |
| `key_phrases` | 1–3 short strings quoting the user's signal-bearing words |
| `confidence` | 0–1 |
| `notes` | one sentence max; empty string when there is nothing to add |
| `attentiveness` | object: `referenced_content`, `answered_posed_question`, `building`, … |

### The word-count gate

```swift
static var sentimentContextLimit: Int = 4

let wordCount = userContentString.split(whereSeparator: \.isWhitespace).count
guard wordCount >= Sinatra.sentimentContextLimit else { /* clear parked, exit */ }
```

A three-word reply carries no reliable signal, and training on it poisons the
model. "ok thanks" teaches nothing.

### Pace and engagement

```swift
// ~3 words/second reading pace (0.3 s/word)
let paceScore = parked != nil ? … : 0     // unmeasurable with no parked turn
let engagementComposite = (paceScore * 0.4) + (attentivenessScore * 0.6)
```

Attentiveness is weighted higher than pace deliberately: *what* the user engaged
with is a better signal than *how fast* they replied.

### Session boundary detection

```swift
let paceCollapse       = paceScore < 0.1
let attentivenessReset = attentivenessScore == 0.0
let sessionBoundary    = paceCollapse && attentivenessReset
// boundaryReason: .both | .paceCollapse | .attentivenessZero
```

Both conditions must hold. A slow reply that still references the content is a
thoughtful reply, not a new session; a fast reply that ignores everything is a
topic change but not a return-after-absence. `sessionBoundary` also fires
`Sewn.AutoMemoryTrigger.topicChange`.

---

## Parking

`Sources/Sinatra/Sinatra+Park.swift`

```swift
static let maxParkedEntries: Int = 30
```

Search results are parked as `SinatraTrainingData.Parked`
(`id`, `documentId`, `partitionCompressedEmbedding`, `distance`) and wait for the
user's next reply to supply the label.

Two details encode past bugs:

```swift
// `default: []` — NOT `default: dataSets`. The latter inserts dataSets as the
// default and then appends them again, storing every initial batch twice.
registry.parked[owner, default: []].append(contentsOf: dataSets)

// Rolling window: the DEFER path (ambiguous + low-confidence sentiment) would
// otherwise accumulate parked data indefinitely across many turns.
if count > Sinatra.maxParkedEntries {
    registry.parked[owner] = Array(registry.parked[owner]!.dropFirst(count - maxParkedEntries))
}
```

Depth is reported as `sinatra.parked_records`.

---

## Inference — Distance Adjustment

`Sources/Sinatra/Sinatra+Inference.swift`

```swift
func infer(_ inference: SinatraInference,
           registry: SinatraRegistry?,
           documentStats: [DocumentID: Sewn.DocumentStats] = [:],
           request: SewnRequest) -> SinatraInference.Result
```

Sinatra does not re-rank by "sentiment score". It **adjusts the PQ distance** of
each retrieved partition: predicted-positive partitions get a lower (better)
distance, predicted-negative a higher one.

> **Pass the registry snapshot in.** Load `sinatra.registry` once *before* a
> search loop and hand it to `infer`. Calling `infer` without it triggers a disk
> read per partition result.

`documentStats` supplies `partitionSentiments[partitionId].averageSentiment` to
the feature vector, so inference reflects **per-partition** engagement rather
than a document-level average.

Every early exit is instrumented with a reason, which is the first thing to check
when tone never changes:

```
sinatra.unadjusted_total{reason="no_registry"}
sinatra.unadjusted_total{reason="no_collector"}
sinatra.unadjusted_total{reason="no_model"}
```

### SinatraAdjustment.Entry

```swift
var factor: Float { adjustedDistance / originalDistance }   // < 1 boosted, > 1 demoted
var wasDropped: Bool { adjustedDistance >= threshold }

enum Status { case boosted, unchanged, demoted, dropped }
// dropped: adjusted ≥ threshold
// boosted: factor < 0.98
// demoted: factor > 1.02
// unchanged: otherwise (includes factor == 1.0, meaning no model applied)
```

---

## Tone — Contraction-Weighted Confidence

`Sources/Sinatra/Models/Sinatra.Tone.swift`

Tone is derived from *how much Sinatra tightened the retrieval distances*, not
from the sentiment label. Tighter distances mean the context is more reliable, so
the model can afford to be more focused.

```swift
static let base = SinatraTone(
    temperature: 0.4, topP: 0.9, repetitionPenalty: 1.1, repetitionContextSize: 20
)
```

Algorithm:

1. Parse every before/after distance across all adjustments.
2. Contraction ratio = `avgOriginal / avgInferred`
   (`> 1` tightened → high confidence; `< 1` expanded → low confidence).
3. Map the ratio from the empirical range `[0.5, 2.0]` onto `[0.0, 1.0]`.
4. Scale each parameter linearly from base toward its high-confidence target:

| Parameter | Base → High confidence | Direction |
|-----------|----------------------|-----------|
| `temperature` | 0.40 → 0.25 | More focused |
| `topP` | 0.90 → 0.75 | Narrower nucleus |
| `repetitionPenalty` | 1.10 → 1.20 | Stronger with rich context |
| `repetitionContextSize` | 20 → 30 | Wider look-back |

With no adjustments at all, `.base` is returned unchanged. Note the direction:
**high confidence lowers temperature.** A grounded answer should not wander.

---

## Gradient Boosted Trees

```
Sources/Sinatra/ML/GBT/
  ├── GradientBoostedTrees.swift  — the ensemble (predict, add tree)
  ├── GBTTrainer.swift            — the training loop
  └── GBTHyperparameters.swift    — defaults + adaptive sizing
```

This is **GBT regression** on the distance target, not classification.

| Hyperparameter | Default | Meaning |
|---------------|---------|---------|
| `nEstimators` | 50 | Boosting rounds |
| `maxDepth` | 4 | Max depth per regression tree |
| `learningRate` | 0.1 | η, per-tree shrinkage |
| `subsample` | 0.8 | Row subsampling per tree |
| `colsampleByTree` | 0.8 | Column subsampling per tree |
| `regLambda` | 1.0 | L2 leaf regularization |
| `regAlpha` | 0.1 | L1 leaf regularization |
| `minChildWeight` | 3.0 | Min sum of hessians for a valid child |
| `minSplitGain` | 0.0 | γ, min gain to create a split |

`GBTHyperparameters.adaptive(datasetSize:)` resizes these at train time — a new
owner with 20 samples does not get a 50-tree ensemble.

**Why GBT and not a neural model?** Interpretable (`POST /v1/frank/gbt` dumps the
trees), sub-millisecond inference, and trainable on 50–200 samples — which is
what "per-owner" actually means on commodity hardware.

---

## IMBHS — What It Actually Optimizes

`Sources/Sinatra/ML/HarmonyMemory.swift` + `IndicatorPeriods.swift`

This is the part most often misdescribed. IMBHS does **not** tune sentiment
weights. Its decision-variable vector is `IndicatorPeriods` — the **11 lookback
windows** of the technical indicators that feed the GBT feature vector.

```swift
struct IndicatorPeriods {           // the 11 IMBHS dimensions
    var emaPeriod, smaPeriod: Int                            // level
    var macdFast, macdSlow, macdSignalPeriod: Int            // EMA momentum
    var stochKPeriod, stochDSignal: Int                      // oscillators
    var momentumPeriod, velocityPeriod: Int                  // raw differentials
    var avgVolPeriod, vwaPeriod: Int                         // volume
}
```

Parameters:

| Constant | Value | Meaning |
|----------|-------|---------|
| `memorySize` | 10 | H, harmonies retained |
| `hmcr` | 0.9 | Harmony memory considering rate |
| `parMin` → `parMax` | 0.1 → 0.5 | Pitch adjustment rate, rises **linearly** over NI |
| `bwMax` → `bwMin` | 3 → 1 | Period step per dimension, decays **exponentially** over NI |
| `ni` | 200 | Optimization horizon in cycles |
| `cadence` | 5 | Runs every 5 training cycles |
| `warmup` | 20 | Minimum cycles before activation |
| `fitnessThreshold` | 0.01 | Requires a 1% MAE improvement to apply |

**Fitness is MAE — lower is better**, and `.infinity` marks an unevaluated
harmony. `Codable` conformance maps non-finite fitness to
`Double.greatestFiniteMagnitude`, because `.infinity` is not representable in a
property list.

Improvisation is textbook IMBHS: with probability HMCR pick a value from memory
and then with probability PAR nudge it by ±BW; otherwise pick uniformly within
bounds. Rising PAR plus shrinking BW means the search explores widely early and
refines late.

Reference: [Improved Music Based Harmony Search Algorithm for Optimal Network
Reconfiguration](https://www.researchgate.net/publication/261109581_Improved_Music_Based_Harmony_Search_algorithm_for_Optimal_Network_Reconfiguration).

---

## Technical Indicators

`Sources/Sinatra/ML/TechnicalIndicators.swift` — financial time-series features
applied to the sentiment/distance series. Every period argument is what IMBHS
tunes.

| Method | Default period(s) |
|--------|------------------|
| `emaWA(period:alpha:)` | 10, α 0.3 |
| `smaWA(period:)` | 20 |
| `macD(fastPeriod:slowPeriod:)` | 5 / 15 |
| `macDSignal(macdHistory:signalPeriod:)` | 9 |
| `macDPreviousSignal(macdHistory:)` | — |
| `stochasticK(period:)` | 14 |
| `stochasticD(period:signalPeriod:)` | 14 / 3 |
| `momentum(period:)` | 10 |
| `velocity(period:)` | 10 |
| `avgVolChange(period:lifetimeAvgInterval:)` | 10 |
| `volumeWeightedAverage(period:)` | 15 |

The intuition: sentiment that has declined for ten turns should produce a
different adjustment than sentiment that just dipped once.

---

## Registry & Persistence

`SinatraRegistry` holds all Sinatra state for all owners, keyed by
`SewnRegistry.Owner`:

```
models[owner]             — the per-owner GBTModel
collectors[owner]         — RetrievalDataCollector (feature history)
parked[owner]             — parked entries awaiting a label (cap 30)
lastSearchEntries[owner]  — SinatraAdjustment.Entry records for Frank
harmony memory            — IMBHS state
```

Persisted through `SewnCache<SinatraRegistry>` over
`FilePersistence(key: "sinatra/registry")`. Note the size characteristic: GBT
trees serialize into the registry, so per-owner state grows with model size.
Compaction of old training data is future work.

---

## Frank — Debug Routes

| Route | Purpose |
|-------|---------|
| `POST /v1/frank/gbt` | Full GBT state — trees, hyperparameters, feature names |
| `POST /v1/frank/parking` | Live pipeline snapshot: parked entries, last search adjustments |
| `POST /v1/frank/reset` | Wipe all Sinatra state for the authenticated owner |
| `POST /v1/frank/export` | Export the owner's Sinatra state |
| `POST /v1/frank/import` | Import previously exported state |
| `POST /v1/admin/sinatra/gbt` | Same as `/v1/frank/gbt`, for any owner (admin) |

Use Frank when tone never changes (check `sinatra.unadjusted_total` reasons
first), when temperature pins to an extreme (inspect trees for overfit), or when
parked data looks stale.

Export/import is covered by `Flow3_SinatraExportImportTests.swift`; the reset
path by `Flow3_SinatraResetTests.swift`.

---

## Metrics

| Metric | Meaning |
|--------|---------|
| `sinatra.inferences_total` | GBT inference calls |
| `sinatra.adjustments_total` | Inferences where an adjustment was applied |
| `sinatra.unadjusted_total{reason}` | Early exits, by reason |
| `sinatra.parked_records` | Parked entries for the last owner touched |
| `sinatra.sentiment_weight` / `sinatra.sentiment_confidence` | Last scored turn |
| `sinatra.feature_vectors_generated_total` / `…_skipped_total` | Feature construction |
| `sinatra.dataset_size` | Training set size |
| `sinatra.training_duration` | Train time |
| `sinatra.model_trees_total` | Ensemble size |
| `sinatra.model_initial_prediction` | The ensemble's base prediction |

---

## Building a New Feature That Touches Sinatra

1. **New feature in the vector** → `RetrievalDataCollector+Models.swift`, compute
   it in `TechnicalIndicators.swift`. If it has a lookback window, add the
   dimension to `IndicatorPeriods` **and** its bounds, or IMBHS will not tune it.
2. **New tone parameter** → `SinatraTone` + the scaling table in `from(_:)`.
   Document base and high-confidence targets.
3. **New GBT hyperparameter** → `GBTHyperparameters` plus `adaptive(datasetSize:)`.
4. **Changing a gate** → `sentimentContextLimit`, `resonanceConfidenceThreshold`,
   or the session-boundary conditions. These are the guards that keep the model
   from training on noise; loosen them with tests.
5. **New registry field** → remember it serializes into every owner's state, and
   that non-finite doubles cannot go into a property list.
6. **Tests** → `Flow3_Sinatra*.swift` (GBT, memory bounds, park alignment, reset,
   export/import).

---

## Known Gaps

- Tone is derived from retrieval contraction, not directly predicted. The
  long-term plan is for GBT to output tone parameters as continuous targets.
- `Gita.Payload.dataSets` is reserved for feeding Sinatra trajectory predictions
  into royalty weighting; not wired.
- Sentiment requires an LLM round trip per turn. On the `local` provider it is
  **off** unless `SEWN_LOCAL_UTILITY=1`, because on one GPU it serializes behind
  every turn.
