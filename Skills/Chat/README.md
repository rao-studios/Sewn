# Chat & Completions

The chat completion path is the most composed thing in Sewn: retrieval, sentiment
tuning, persona resolution, provider selection, attribution, and pricing all meet
in one turn. This document covers `/v1/chat/completions` and its four deliberately
simpler siblings.

---

## The Five Generation Routes

| Route | Persona | Thread RAG | Gita | Tools | Shape |
|-------|---------|-----------|------|-------|-------|
| `POST /v1/chat/completions` | ✅ | ✅ | ✅ | — | JSON or SSE |
| `POST /v1/complete` | — | — | — | — | One POST, one JSON body |
| `POST /v1/skills/complete` | — | — | — | ✅ roles + tool roster | May return `tool_calls` |
| `POST /v1/code/complete` | — | — | — | ✅ file-tool roster | Model pinned by Sewn |
| `POST /v1/realtime/chat` | ✅ | ✅ | ✅ | — | WebSocket, two-pass — see `Skills/Realtime/README.md` |

The siblings exist because the chat pipeline is wrong for bounded jobs. From
`Complete.swift`:

> **ONE BOUNDED GENERATION**, no persona, no Thread RAG, no Gita contribution.
> `/v1/chat/completions` always runs `_processUserMessages` — personality,
> retrieval, auto_memory, and a trailing contribution chunk. Jobs that need a
> JSON object and nothing else cannot survive that pipeline: the model answers in
> prose about the file and the caller parses nothing.

Distinctions worth keeping straight:

- **`/v1/complete`** flattens messages into one user blob and ignores tools.
  There is no `sewn` scope object on the wire — nothing is stored, so nothing
  needs an owner.
- **`/v1/skills/complete`** keeps roles, offers the caller's tool roster, and may
  return `tool_calls`. It is Mary's ability roster. Mary's *spoken* lane stays on
  `/v1/chat/completions`.
- **`/v1/code/complete`** is the pair-coding file-tool roster.
  `typealias CodeCompleteRequest = SkillsCompleteRequest`. Mary never sends a
  model id, so `ModelConfig.codingModel` is Sewn's pin (Codestral by default).
  Max tokens are clamped: `min(max(requested ?? 2048, 32), 4096)`.

---

## Request Shape

```swift
struct ChatCompletionRequest: Codable {
    let messages: [ChatMessageRequestData]
    let model: String?
    let maxTokens: Int?          // "max_tokens"
    let temperature: Float?
    let topP: Float?             // "top_p"
    let stream: Bool?
    let stop: [String]?
    let repetitionPenalty: Float?      // "repetition_penalty"
    let repetitionContextSize: Int?    // "repetition_context_size"
    var instructions: String?
    var personality: String?
    var persona: ChatPersona?
    var resonate: Bool?
    var debug: Bool?
    var client: String?          // "bonnie" reframes retrieved context
    var provider: LLMProvider?   // mistral | tinker | local
    let sewn: SewnRequest
    // VLM: resize, kvBits, kvGroupSize, quantizedKVStart
}
```

`ContentFragmentType` is `.text(String)`, `.fragments([ContentFragment])`, or
`.none`, decoded from a single-value container — so a message's `content` accepts
both a plain string and a multi-modal array.

---

## The Pipeline

```
POST /v1/chat/completions
    │
    ├─ AuthMiddleware → context.authUserId
    ├─ Route reads the body ONCE to branch on `stream`, then hands the
    │  DECODED request to the handler
    │       ⚠️ The body iterates once. Decoding again in the handler traps.
    │
    ├─ sewnRequest = chatRequest.sewn.from(context)   // owner_id overwritten
    │
    ├─ _processUserMessages(…) → ChatResult           // the shared pipeline
    │   │
    │   ├─ [concurrent] Sinatra.prepare → sinatraTask (NOT awaited yet)
    │   ├─ [concurrent] fanoutSearch → partitions + graph trace
    │   ├─ Gita.track(.inference) → unpriced word-count shares
    │   ├─ compact(…) → briefing text, compactCitations, sourceIndex
    │   ├─ Resolve personality / persona
    │   └─ Assemble persona + instructions + context + citation protocol
    │
    ├─ Resolve provider, model, and token budget
    ├─ Resolve generation parameters (precedence below)
    │
    ├─ ModelProvider.run / stream → text with [[n]] markers
    │
    ├─ await chatResult.sinatraTask
    │     ├─ merge result.ledger into the turn's TokenLedger
    │     └─ sewn.accumulatePerformance(result.documentStatsUpdates)
    │
    ├─ Gita.parseMarkers → strip markers, resolve spans
    ├─ Gita.priceContribution(ledger) → earnings, service charge, total
    ├─ sewn.accumulateEarnings(from:)
    └─ Response — choices, usage, personality, contribution
```

### ChatResult — what the pipeline hands the handler

```swift
struct ChatResult {
    let input: UserInput
    let references: [Sewn.DocumentReference]
    let partitions: [Sewn.Partition]              // retained for post-generation spans
    let compactCitations: [Gita.CompactCitation]  // highest-confidence span seed
    let sourceIndex: [Int: DocumentID]            // [n] tag → document, for [[n]] markers
    let personality: Personality?
    let contribution: Gita.Contribution?
    let tone: SinatraTone?
    let autoMemory: Bool
    let sinatraTask: Task<Sinatra.PrepareResult?, any Error>?
}
```

`sinatraTask` is the concurrency seam. Sinatra's sentiment analysis runs
**alongside** the primary generation; the handler awaits it afterwards to merge
the ledger before pricing and to persist document stats. It is `nil` when Sinatra
was not invoked — the VLM path, for instance.

---

## Generation Parameter Precedence

This is not uniform across parameters, and the asymmetry is deliberate.

```swift
// Explicit request > personality (deliberate persona choice) > adaptive tone > defaults
let temperature = chatRequest.temperature
    ?? personality?.temperature
    ?? sinatraTone?.temperature
    ?? GenerationDefaults.temperature

let topP = chatRequest.topP
    ?? personality?.topP
    ?? sinatraTone?.topP
    ?? GenerationDefaults.topP

// Tone FIRST for the repetition controls
let repetitionPenalty = sinatraTone?.repetitionPenalty
    ?? chatRequest.repetitionPenalty
    ?? GenerationDefaults.repetitionPenalty

let repetitionContextSize = sinatraTone?.repetitionContextSize
    ?? chatRequest.repetitionContextSize
    ?? GenerationDefaults.repetitionContextSize
```

`temperature` and `topP` are things a caller means to control, so an explicit
value wins. The repetition controls are retrieval-quality artifacts — Sinatra
knows how much context it just tightened, and a client guessing a penalty does
not — so **tone wins there**.

### Model and token budget

```swift
let provider = chatRequest.provider ?? .serverDefault
let requestedModel = chatRequest.model ?? personality?.modelOverride
let resolvedModel = ModelConfig.resolveChatModel(requested: requestedModel, provider: provider)
let maxTokens = ModelConfig.chatMaxTokens(requested: chatRequest.maxTokens, model: resolvedModel)
```

**Model is resolved before the token budget on purpose:** thinking models get a
floor (`ModelConfig.thinkingTokenFloor = 4096`) so truncation never swallows the
answer. A reasoning model handed 128 tokens spends them all thinking.

### GenerationDefaults

```swift
static let maxTokens = 128
static let temperature: Float = 0.8
static let topP: Float = 1.0
static let stream = false
static let repetitionPenalty: Float = 1.0
static let repetitionContextSize = 20
static let stopSequences: [String] = []
static let kvGroupSize = 64
static let quantizedKVStart = 0
```

These are the floor beneath everything, and `maxTokens = 128` is low — nearly
every real path overrides it. Changing these affects **every** user on the
server.

---

## Personalities

```swift
struct Personality: Codable, Sendable, Equatable, Identifiable {
    var id, name, tagline: String
    var systemFragment: String
    var citationEmphasis: Bool
    var temperature: Float?
    var topP: Float?
    var modelOverride: String?
}
```

Held in a `LockedValue<[Personality]?>`, lazily loaded from
`FilePersistence(key: "personalities")`, falling back to `Personality.defaults`.

| Route | Purpose |
|-------|---------|
| `GET /v1/personalities` | List personas |
| `PUT /v1/admin/personalities` | Replace the list (admin) |

`ResolvedChatPersona` (`name`, `voice`, `citationEmphasis`) is what the request's
`persona` field resolves to, with `.default` as the fallback. Note that a
personality can override the model — and that override sits *below* an explicit
request `model`.

---

## Client Framing

```swift
/// Which client is speaking — "bonnie" switches retrieved context to …
var client: String?
```

```swift
let isBonnieClient = request.client?.lowercased() == "bonnie"
static let bonnieToolDocumentPrefix = "bonnie-tool-"
```

A request carrying `client: "bonnie"` is reframed so retrieval becomes **support
for the current request** — background that helps, never material that redirects.
That client's own tool-action deposits (`bonnie-tool-…` documents) render as a
separate tier the model is told not to recite.

This is the pattern for adding a MaryOS surface: a named client with its own
context framing, not a new route.

---

## Compaction and the Citation Protocol

See `Skills/Sewn/README.md` for `Sewn+Compact.swift` in detail. What matters here:

- Retrieved partitions are summarized into a **briefing**, unless total partition
  characters are at or under `verbatimContextThreshold = 6000`, in which case
  context is injected verbatim and no LLM call is made.
- Sources are rendered into the prompt as bracketed `[n]` tags. `sourceIndex`
  maps `n → DocumentID` **in exactly the order the tags were rendered**.
- The model is instructed to append invisible `[[n]]` markers to sentences drawing
  on source `[n]`.
- `compactCitations` (empty on the verbatim path) is the highest-confidence span
  seed.

---

## Streaming

`stream: true` returns `text/event-stream` with `ChatCompletionChunkResponse`
deltas and `responseId` of the form `api-chatcmpl-<uuid>`.

```
data: {"id":"api-chatcmpl-…","choices":[{"delta":{"content":"Hello"}}]}

data: {"id":"api-chatcmpl-…","choices":[],"contribution":{…},"auto_memory":false}

data: [DONE]
```

Three stream-specific behaviors:

- **Markers are stripped from every delta.** They can never reach the client,
  whether or not a contribution exists.
- **The trailing chunk carries the metadata** — empty `choices`, plus
  `contribution` and `auto_memory`. Realtime reuses this exact JSON verbatim as
  its `metadata` frame, which is why clients can share one chunk Codable.
- **Billing finalizes at stream end** (`Gita+StreamBilling.swift`). A client that
  disconnects mid-stream is billed for the tokens actually generated.

Metrics: `sewn.chat.ttft`, `sewn.chat.stream_duration`,
`sewn.chat.search_duration`, `sewn.chat.compact_duration`.

---

## Non-Streaming Response

```json
{
  "choices": [{ "message": { "role": "assistant", "content": "..." }, "finishReason": "stop" }],
  "usage": { "prompt_tokens": 120, "total_tokens": 350 },
  "personality": "scholar",
  "contribution": {
    "owners": [{ "spans": [], "document_spans": { "did": [{ "lower": 0, "upper": 42 }] } }]
  }
}
```

---

## Other Generation-Adjacent Routes

| Route | Notes |
|-------|-------|
| `POST /v1/tools/summarize` | Single-shot summarization. No RAG, no Sinatra |
| `POST /v1/vision/look` | Mistral vision. Describe a screen region, or compose a Design Plan that recreates it. Nothing stored, streamed, or retained |
| `POST /v1/embed` | **Returns the vector.** No storage side effect — see below |
| `POST /v1/speak` | Mistral TTS proxy, PCM stream |

### `/v1/embed` vs `/v1/embeddings`

A distinction that has caused real confusion:

- **`/v1/embeddings` is an INGEST route.** It chunks text, hashes a document id,
  fans out into Thread, and answers `{success: true}`.
- **`/v1/embed` returns the vector itself**, for a caller scoring against its own
  corpus in its own process — Mary's on-device routing indexes. Same vendor, same
  model, same vector space.

> **PIN: NO STORAGE SIDE EFFECT.** If `/v1/embed` ever indexes, a caller warming
> a corpus of a few hundred trigger sentences would silently fill the user's
> thread with them.

---

## Error Cases

| Scenario | Response |
|----------|---------|
| Missing or invalid bearer | 401 |
| Unknown `provider` value | 400 |
| Provider key missing | 503 naming the env var |
| `local` on a non-MLX build, or no Metal library | 503 naming the reason |
| No last user message | Empty `ChatResult` — the turn returns, it does not throw |
| No Thread connected / zero active nodes | Chat proceeds with no context |
| Search returns nothing | Chat proceeds with no context |
| Sinatra fails | `sinatraTask` throws; tone falls back to `.base` |
| Client disconnects mid-stream | Billing finalizes on tokens sent |

The pattern throughout: **degrade, don't fail.** Retrieval, sentiment, and
attribution are all optional to producing an answer.

---

## VLM

`--vlm` enables multi-modal input. `UserInput` carries `images` and `videos`, and
`resize` / `kvBits` / `kvGroupSize` / `quantizedKVStart` on the request are the
VLM knobs. On this path `sinatraTask` is `nil` — sentiment does not run.

---

## Working on Chat

1. **New request field** → `ChatCompletionRequest`. Realtime gets it free, since
   `RealtimeTurnStart.request` is the same Codable.
2. **New pipeline stage** → `_processUserMessages`, and surface its output on
   `ChatResult` rather than on a side channel.
3. **New parameter** → decide precedence deliberately. Caller intent wins for
   things a caller means; tone wins for retrieval-quality artifacts.
4. **Never re-decode the request body in a handler.** The route already consumed
   it to branch on `stream`.
5. **Anything that must survive both transports** → put it in the trailing chunk
   JSON, which realtime forwards verbatim.
6. **Tests** → `ChatPersonaTests`, `RequestResponseTests`,
   `TextCompletionParametersTests`, `MarkerSpanTests`, `RealtimeTests`,
   `Flow6_AutoMemoryTests`.
