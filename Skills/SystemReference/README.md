# System Reference

Complete reference documentation for the Sewn server architecture and API.

## Contents

| File | Purpose |
|------|---------|
| [Architecture.md](Architecture.md) | Full system architecture — component map, request lifecycle, design decisions, startup sequence |
| [RouteReference.md](RouteReference.md) | Every API route — method, path, auth, request/response schema, business logic |
| [DataModels.md](DataModels.md) | All Swift types — Sewn, Sinatra, Gita, Oracle, API models |

## When to Use

- **Adding a new endpoint**: Read `RouteReference.md` for conventions, `DataModels.md` for existing types to reuse.
- **Understanding how systems connect**: Read `Architecture.md` — specifically the request lifecycle diagrams.
- **Debugging unexpected behavior**: The actor concurrency section in `Architecture.md` explains why mutations are serialized and which actors own what.
- **Onboarding**: Read `Architecture.md` top-to-bottom first, then `RouteReference.md`.
