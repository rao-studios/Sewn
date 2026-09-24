# Providers — Which Backend Answers

Every generation route takes an optional `provider` on the request body. Omit it
and the server default applies, so a client that never heard of providers is
unaffected. There are three:

```swift
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case mistral   // Mistral's hosted API (chat-completions wire)
    case tinker    // Thinking Machines' Tinker (Anthropic-compatible Messages wire)
    case local     // This machine, through Frigate MLX inside Sewn
}
```

> **PIN: the raw values are the wire.** They are shared with Mary's
> `LLMEngineChoice` — `"mistral" | "tinker" | "local"`. Never rename a case.

Source: `Sources/Core/LLMProvider.swift`, `Sources/Core/ModelConfig.swift`,
`Sources/Providers/`, `Sources/API/Routes/Providers.swift`

---

## Resolution — How a Turn Picks Its Backend

```
Generation request
    │
    ├─ provider on the body?
    │    NO  → LLMProvider.serverDefault
    │          (SEWN_GLOBAL_LLM; Mistral when unset OR UNKNOWN)
    │    YES → known value? NO → 400 unknown provider
    │                       YES ↓
    ├─ Selected provider
    │
    ├─ Can it serve?
    │    key missing                       → 503 naming the env var
    │    no Metal library / non-macOS build → 503 naming the reason
    │    GPU requirements unmet             → 503 with LocalGPU.remedy()
    │    YES ↓
    │
    ├─ Client named a model?
    │    yes, and it belongs to this provider's family → use it
    │    yes, but the WRONG family → IGNORED, fall through to config
    │    no  → the provider's configured model
    │
    └─ Run the turn
         └─ provider == .local?
              YES → sentiment, compaction, auto-memory follow the turn
                    on-device; OFF unless SEWN_LOCAL_UTILITY=1.
                    NO OUTBOUND REQUEST AT ALL.
              NO  → utility passes run on mistral-tiny
```

Note the two deliberate non-failures:

- `serverDefault` falls back to `.mistral` for an **unknown** `SEWN_GLOBAL_LLM`
  value, not just an unset one. A typo in `.env` does not stop the server.
- A client-supplied model from the wrong family is **silently ignored**, not an
  error. This is what prevents a `tinker://` id from ever being posted to
  Mistral's host.

---

## ProviderUnavailable

```swift
enum ProviderUnavailable: Error, CustomStringConvertible, Equatable {
    case missingKey(envVar: String)
    case localNotBuilt
    case localFailed(String)
    case utilityDisabled(LLMProvider)
}
```

Each case's `description` is user-facing text naming the fix, e.g.
*"Missing MISTRAL_API_KEY — add it to Sewn's .env or export it before starting
Sewn."* Routes map these to **503**, never to a crash. A mis-toggled provider is
an error the client can read.

---

## ModelProvider

`Sources/Providers/ModelProvider.swift`

```swift
final class ModelProvider {
    private let hosted: [NetworkService.BaseEndpoint: NetworkService]  // one per vendor
    let local: LocalInference                                          // this machine
}
```

> One client **per hosted vendor**, built once and chosen per request. This used
> to be a single client frozen at init to the boot-time default — which is
> exactly how a `tinker://` model once reached Mistral's host.

`run(_:generationParameters:maxTokens:model:provider:logger:)` handles the wire
difference between the two hosted vendors: a leading or trailing `system`-role
message is hoisted out of `messages` and re-attached per provider — Anthropic's
top-level `system` field for Tinker, an inline leading system message for
Mistral. Multiple system messages are joined with `\n\n`.

`ModelProvider+Stream.swift` is the streaming counterpart.

---

## ModelConfig — Which Model Serves Each Job

`Sources/Core/ModelConfig.swift`. Seeded from the environment, with runtime
overrides.

| Job | Resolver | Env var | Default |
|-----|----------|---------|---------|
| Chat (mistral) | `chatModel(for:)` | `SEWN_CHAT_MODEL` | `mistral-medium-latest` |
| Chat (tinker) | `chatModel(for:)` | `TINKER_MODEL` | `thinkingmachines/Inkling-Small` |
| Chat (local) | `chatModel(for:)` | `SEWN_LOCAL_MODEL` | `mlx-community/Mistral-Nemo-Instruct-2407-4bit` |
| Utility one-shots | `utilityModel(for:)` | `UTILITY_MODEL` | `mistral-tiny` |
| `/v1/code/complete` | `codingModel(for:)` | `SEWN_CODING_MODEL` | `codestral-latest` |
| `/v1/code/complete` (local) | `codingModel(for:)` | `SEWN_LOCAL_CODING_MODEL` | falls back to `chatModel(for: .local)` |
| Vision | `visionModel` | `VISION_MODEL` | `mistral-medium-latest` |
| Realtime opening pass | `openingModel` | `SEWN_REALTIME_OPENING_MODEL` | a fast non-thinking model |

Key members:

```swift
static func accepts(_ model: String, provider: LLMProvider) -> Bool   // family check
static func resolveChatModel(requested: String?, provider: LLMProvider) -> String
static func chatMaxTokens(requested: Int?, model: String) -> Int
static func isThinkingModel(_ model: String) -> Bool
static func supportsNoThinkSwitch(_ model: String) -> Bool
static let thinkingTokenFloor = 4_096
static let openingMaxTokens = 80

/// Runtime overrides from PUT /v1/admin/model. Empty = follow the env.
private static let overrides = LockedValue<(chat: String, utility: String)>(("", ""))
static func update(chatModel: String? = nil, utilityModel: String? = nil)
```

Two things worth internalizing:

- **Thinking models get a token floor.** `thinkingTokenFloor = 4096` — a
  reasoning model handed a 512-token budget spends it all thinking and emits
  nothing.
- **The Pixtral vision ids are retired.** `visionModel` defaults to
  `mistral-medium-latest`; the API answers vision on the general model now.
- **Adding a model here is half the job.** The other half is adding its pricing
  to the `Gita.TokenLedger` catalog, or every turn using it silently prices at
  `mistral-medium` rates.

---

## The `local` Provider

Runs the model **inside Sewn** through Frigate's MLX — macOS only. Every call
site is behind `#if canImport(MLXLLM)`, and the `Package.swift` products are
conditioned on `.macOS`.

```
Sources/Providers/Local/
  ├── LocalInference.swift    — the actor over SinatraMLX's harness: warm, generate, stream, snapshot
  ├── LocalTurn.swift         — LocalTurnContext, LocalSampling, the `sinatra` request/response types
  ├── LocalGPU.swift          — requirement report + remedy text
  └── LocalMessageMapper.swift — role/content → MLX chat format
```

It needs `mlx.metallib` beside the binary, because SwiftPM has no Metal step:

```sh
swift build -c release
./scripts/build-metallib.sh release
```

### SinatraMLX — the injection layer before decoding

`LocalInference` no longer calls `MLXLMCommon.generate` itself. It hands every
generation to a `SinatraHarness` (SinatraMLX, `../../../repositories/SinatraMLX`),
which owns model residency and the one-generation-at-a-time gate. A **chat turn**
(`runStream`/`run` with `retrieved` + `turn`) goes through these steps:

1. The user's message labels the previous turn from behaviour: reply latency, length,
   and echo of each partition.
2. Only the retrieved partitions are encoded with the model's embedding table.
3. A per-owner time-series model weighs them. The weights are advantages over this
   owner's mean reward, gated by the model's measured skill.
4. A sparse bias over their content tokens is added to the logits before sampling.
5. The turn is recorded, and training runs afterwards when due.

**Utility passes** (the `maxTokens:` overloads, used by compaction, tools and one-shots)
pass no turn, so they get no injection and learn nothing.

| Surface | What changed |
|---|---|
| Request | optional `sinatra: {mode, trace, seed, record}` (validated → 400) |
| SSE / response | trailing `sinatra` object (`LocalSinatraDiagnostics`) |
| `GET /v1/providers` | local row `sinatra` status for the signed-in owner |
| `POST /v1/providers/local/warm` | optional `{"model": …}` body |
| new | `GET /v1/providers/local/sinatra/traces/{id}`, `GET /v1/providers/local/sinatra/analysis` |
| sampling | temperature / top_p / repetition now reach the on-device decode |
| store | `<dataRoot>/sinatra-mlx/`; purged with the owner by the admin owner-delete |

Environment: `SEWN_SINATRA_MODE` (off | lexical | dense), `SEWN_SINATRA_TRACE`
(automatic | off | summary | full), `SEWN_SINATRA_ALPHA`. Tests:
`LocalSinatraTests.swift`; the live two-turn test runs via `./scripts/test-local-sinatra.sh`.
Try it with `swift run sewn-probe chat|compare|providers|trace|analysis`.

### Warming

```
POST /v1/providers/local/warm
```

Idempotent — **a warm already in flight is joined, not restarted.** The route
returns `{ accepted, state, model }` immediately and warms in a detached task.
Startup calls the same path automatically when the default provider is `local`,
so turn one does not pay for the load.

### Utility passes on local

```swift
/// Internal one-shots (Sinatra, auto-memory, compaction, summarize) run
/// on this machine only when opted in: on one GPU they serialize three to
/// five extra generations behind every turn.
static var localUtilityEnabled: Bool   // SEWN_LOCAL_UTILITY ∈ {1, true, yes}
```

This default is the single most important operational fact about `local`. With it
off, a `local` turn makes **no outbound request at all** — sentiment, compaction,
and auto-memory simply do not run rather than quietly reaching a vendor the user
did not choose. With it on, expect three to five extra serialized generations per
turn on a single GPU.

---

## Routes

### `GET /v1/providers`

```swift
struct ProviderInfo {
    var id: String              // "mistral" | "tinker" | "local"
    var displayName: String
    var available: Bool
    var isDefault: Bool         // encoded as "default"
    var state: String           // "ready" | "unconfigured" | "failed" | local state name
    var progress: Double?       // local download/load fraction; nil for hosted
    var model: String           // ModelConfig.chatModel(for:)
    var capabilities: ProviderCapabilities
    var reason: String?         // WHY it cannot serve
}
```

> **PIN: honest about absence.** A provider with no key, or an on-device build
> with no Metal library, reports `available: false` **with the reason** — the
> client shows it rather than discovering it as a failed turn.

Availability means different things per provider, by design: for hosted it is
"is the key here"; for local it is "was this built with MLX, is the Metal library
beside the binary, and are the GPU requirements satisfied".

`ProviderCapabilities` reports `chat`, `skills`, `code`, `complete` as true for
every provider, and `vision`, `embeddings`, `speech` as **false** — those three
are Mistral-served regardless of which provider was chosen.

### `PUT /v1/admin/model` / `GET /v1/admin/model`

Runtime chat and utility model overrides, held in a `LockedValue`. Empty string
means "follow the environment". Not persisted — a restart returns to `.env`.

---

## Which Routes Honor `provider`

| Route | mistral | tinker | local |
|---|---|---|---|
| `/v1/chat/completions` (SSE + non-stream) | ✅ | ✅ | ✅ |
| `/v1/realtime/chat` grounded pass | ✅ | ✅ | ✅ |
| `/v1/skills/complete`, `/v1/code/complete` | ✅ | ✅ | ✅ |
| `/v1/complete` | ✅ | ✅ | ✅ |
| realtime **opening** pass | fast hosted model | fast hosted model | **skipped** — the grounded stream carries the turn |
| Sinatra sentiment / resonance, auto-memory, compaction | `mistral-tiny` | `mistral-tiny` | follows the turn; **off** unless `SEWN_LOCAL_UTILITY=1` |
| `/v1/vision/look`, `/v1/embed`, `/v1/embeddings`, `/v1/speak` | Mistral | Mistral | Mistral — no on-device equivalent yet |

---

## Configuration

```env
# Which backend answers when a request names none. mistral | tinker | local
SEWN_GLOBAL_LLM=mistral

MISTRAL_API_KEY=<key>     # still needed for vision, embeddings and speech
TINKER_API_KEY=<key>      # only for the tinker provider
TINKER_MODEL=thinkingmachines/Inkling-Small

SEWN_CHAT_MODEL=mistral-medium-latest
UTILITY_MODEL=mistral-tiny
SEWN_CODING_MODEL=codestral-latest
VISION_MODEL=mistral-medium-latest
SEWN_REALTIME_OPENING_MODEL=<fast non-thinking model>

# On-device (macOS). Needs ./scripts/build-metallib.sh
SEWN_LOCAL_MODEL=mlx-community/Mistral-Nemo-Instruct-2407-4bit
SEWN_LOCAL_CODING_MODEL=<optional; falls back to SEWN_LOCAL_MODEL>
SEWN_LOCAL_UTILITY=0      # 1 lets Sinatra/auto-memory/compaction run on-device
```

A missing key is reported **per request** as a 503 naming the variable, and shows
as `available: false` on `GET /v1/providers`. It never stops the server.

---

## Adding a Provider

1. Add the case to `LLMProvider` — **append**, never rename, and pick a raw value
   Mary's `LLMEngineChoice` will also use.
2. `hostedBase` for a hosted vendor (plus a `NetworkService.BaseEndpoint` with
   its `apiKeyEnvVar`), or extend the local branch.
3. Resolvers in `ModelConfig`: `chatModel(for:)`, `utilityModel(for:)`,
   `codingModel(for:)`, and `accepts(_:provider:)` so family checks work.
4. Wire construction in `ModelProvider.init` and the request path in `run` /
   the stream variant, handling the vendor's system-message convention.
5. Add pricing for its models to the `Gita.TokenLedger` catalog.
6. `providerInfo(_:localState:localBuilt:)` — availability, state, and a real
   `reason` string for every way it can fail.
7. Tests: `ProviderRoutingTests.swift`, `LLMProviderTests.swift`.

---

## Tests

| File | Covers |
|------|--------|
| `ProviderRoutingTests.swift` | Resolution, family rejection, 400/503 mapping |
| `LLMProviderTests.swift` | The enum, `serverDefault`, `localUtilityEnabled` |
| `TextCompletionParametersTests.swift` | Parameter and max-token resolution |
| `CompleteTests.swift`, `SkillsCompleteTests.swift`, `CodeCompleteTests.swift` | Per-route bounded generation |
| `VisionLookTests.swift` | The Mistral-only vision path |
