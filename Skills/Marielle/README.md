# Marielle — Personalization Layer

> **Status: Not yet implemented.** All four routes (`/v1/marielle/open`, `/v1/marielle/proactive`, `/v1/marielle/interject`, `/v1/marielle/bridge`) return `503 Service Unavailable`. The implementation was designed against a local HNSW graph; it needs to be rewritten to query Totem nodes via gRPC fan-out.

---

## What Marielle Does

Marielle generates personalized, context-aware conversational questions from a user's document history:

- **Open** — recency-weighted ice-breaker question for a new session (most recent docs weighted highest)
- **Proactive** — lightweight check: does Marielle have something worth saying?
- **Interject** — mid-session lateral question scored against live conversation context (Jaccard drift)
- **Bridge** — question bridging two users' intellectual worlds (overlap or contrast)

All four use LLM prompts (`MariellePrompts`) with tight word-count constraints (max 25–30 words) to produce natural, non-interrogative questions.

---

## What Needs to Be Done

1. **Replace local HNSW access** with `fanoutSearch()` or a dedicated `fanoutPersonalGraph()` primitive to fetch the user's top-k recent partitions from Totem nodes.
2. **Wire the route handlers** in [Marielle.swift](../Sources/API/Routes/Marielle.swift) — all logic (prompts, Jaccard drift, bridge scoring) is already written; only the graph access layer is missing.
3. **Bridge route** additionally needs a second owner's partitions, requiring cross-owner Totem fan-out with access gating.

---

## Prompts (already implemented)

| Route | Prompt strategy |
|-------|----------------|
| `open` | System: "ask one curious question from recent docs (most recent first)" |
| `interject` | System: "lateral question based on conversation drift + nearby unused material" |
| `bridge` | System: two variants — overlap (shared interest) or contrast (different worlds) |

The prompts are in `MariellePrompts` (private enum in [Marielle.swift](../Sources/API/Routes/Marielle.swift)). They are already well-tuned; don't change them without testing.
