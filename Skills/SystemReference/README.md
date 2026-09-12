# System Reference

Complete reference documentation for the Sewn server architecture and API.

## Contents

| File | Purpose |
|------|---------|
| [Architecture.md](Architecture.md) | Component map, actors, request lifecycles, storage layout, startup sequence, design rationale, and a "where things moved" table |
| [RouteReference.md](RouteReference.md) | Every registered route — method, path, tree, auth, schema, notes — plus removed route families |
| [DataModels.md](DataModels.md) | Every Swift type that is persisted, sent on the wire, or shared between subsystems |

## When to Use

- **Adding an endpoint** — `RouteReference.md` for conventions and the
  registration rules, `DataModels.md` for types to reuse.
- **Understanding how systems connect** — `Architecture.md`, specifically the
  component map and the two request lifecycles.
- **Debugging unexpected behavior** — the concurrency section of
  `Architecture.md` explains what is serialized and which actor owns what.
- **Onboarding** — read `Architecture.md` top to bottom, then skim
  `RouteReference.md`.
- **Wondering where something went** — the "Where Things Moved" table at the end
  of `Architecture.md`, and the removed-routes and removed-types sections of the
  other two files.

## The Two Facts That Explain Everything Else

1. **Sewn stores no vectors, no HNSW graph, and no knowledge graph.** Thread
   nodes hold all of it and dial *in* over gRPC. `SewnRegistry` is billing stats
   only.
2. **Every route must be registered before `Application.init`**, which freezes
   the Hummingbird responder. A route added afterwards is silently unreachable.
