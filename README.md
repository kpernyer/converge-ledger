# Converge Ledger

**An optional, distributed, append-only runtime substrate for Converge**

⸻

## What This Is

Converge Ledger is a supporting runtime component for the Converge engine.

It exists to externalize ephemeral context from a running Converge process when scale, distribution, or observability demands it — without ever becoming a source of semantic truth.

Convergence happens in Rust.
Anything distributed only exists to remember what already happened.

The ledger does not decide, coordinate, or validate anything.
It cannot cause convergence.
It cannot break convergence.

If Converge Core did not exist, this system would be meaningless.

⸻

## What This Is Not

To avoid architectural drift, this is explicit:

- ❌ Not a coordination layer
- ❌ Not a workflow engine
- ❌ Not an agent communication bus
- ❌ Not a CRDT for reasoning
- ❌ Not a replacement for Converge Core
- ❌ Not required for correctness

Converge Ledger is derivative, optional, and replaceable.

⸻

## Why This Exists

Converge Core is designed around:

- Single-root intent
- Append-only semantic context
- Deterministic convergence
- Explicit authority
- Provable invariants

In many cases, a single Rust process is sufficient.

However, some deployments benefit from:

- Large contexts that exceed process memory
- Multiple engine instances observing the same context
- Real-time inspection and debugging
- Fast recovery after restart
- Horizontal scaling at the job level

Converge Ledger exists only to support these cases — as a runtime substrate, not a conceptual pillar.

⸻

## Design Principle

The ledger never knows why something happened.
It only knows that it happened.

All meaning lives in Converge Core.

⸻

## The Data Model

The ledger stores append-only entries, grouped by context ID.

Each entry is:

- Sequential
- Immutable
- Timestamped
- Typed (fact, proposal, eval, trace, etc.)
- Opaque to the ledger itself

```
┌─────────────────────────────────────────────────────────┐
│ Context: growth-strategy-001                             │
├──────────┬────────────┬─────────────────────────────────┤
│ seq=1    │ facts      │ market_size: 2.4B               │
│ seq=2    │ intents    │ objective: increase_demand      │
│ seq=3    │ traces     │ agent:analyst started           │
│ seq=4    │ proposals  │ strategy: partnership_model    │
│ seq=5    │ evals      │ confidence: 0.73                │
│   ⋮      │    ⋮       │        ⋮                        │
└─────────────────────────────────────────────────────────┘
```

There are no updates, deletes, or rewrites.

⸻

## Consistency Model

- Single-writer per root intent (the Converge engine)
- Multiple readers (other engines, observers, tools)
- Append-only semantics guarantee:
  - No conflicts
  - No merge logic
  - No semantic ambiguity

Replication exists to mirror state, not to resolve meaning.

⸻

## Why Elixir / OTP

Converge Ledger is implemented in Elixir on OTP because it provides:

**Lightweight Concurrency**

Millions of isolated processes with minimal overhead.

**Fault Isolation**

Failures restart locally without corrupting state.

**Distribution**

Node discovery, clustering, and replication are built-in.

**In-Memory Performance**

Reads and writes operate at microsecond scale.

**Operational Simplicity**

This is solved infrastructure — not a research problem.

⸻

## Durability Model

The ledger is not authoritative.

- Losing ledger data must not break correctness
- Converge Core can always regenerate context
- Persistence exists for operational convenience, not truth

Mnesia supports:

- In-memory tables (ram_copies)
- Disk-backed tables (disc_copies)

Use durability when needed — but never rely on it for semantics.

⸻

## API (Minimal by Design)

The ledger exposes exactly five operations:

| Operation | Purpose |
|-----------|---------|
| Append | Add an entry to a context |
| Get | Retrieve entries |
| Snapshot | Serialize a context |
| Load | Restore a context |
| Watch | Stream new entries |

Deliberately missing:

- Updates
- Deletes
- Transactions
- Branching
- Conditional writes

If you need those, you're using the wrong system.

⸻

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│               Converge Core (Rust – Authority)               │
│                                                             │
│  • Root intent                                               │
│  • Convergence logic                                         │
│  • Invariant enforcement                                    │
│  • HITL gating                                               │
└───────────────────────────────┬─────────────────────────────┘
                                │ gRPC
                                ▼
┌─────────────────────────────────────────────────────────────┐
│             Converge Ledger (Elixir – Substrate)              │
│                                                             │
│  • Append-only storage                                      │
│  • Replication & catch-up                                   │
│  • Watch streams                                            │
│  • Snapshot / restore                                       │
│                                                             │
│   No decisions • No validation • No authority               │
└─────────────────────────────────────────────────────────────┘
```

⸻

## When to Use This

Use Converge Ledger when you need:

- Distributed observation of a running convergence
- Fast restart without recomputation
- External tooling (debuggers, dashboards)
- Large or long-running contexts
- Multi-node execution per job

Do not use it:

- As a replacement for Converge Core
- As an agent communication layer
- As a general-purpose database

⸻

## The Contract

This repository obeys one rule:

**Nothing in this system may influence convergence semantics.**

If a proposed change violates that rule, it does not belong here.

⸻

## Documentation

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Detailed architecture, design decisions, and implementation details
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Development setup, testing requirements, and contribution guidelines
- **[LICENSE](LICENSE)** — MIT License

⸻

## License

MIT

⸻

## Final Note

Converge is built on the idea that systems should halt, explain themselves, and resume safely.

This ledger exists only to make that practical at scale —
never to make it ambiguous.
