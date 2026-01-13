# Converge Ledger — Architecture

## Purpose

Converge Ledger is an optional, distributed, append-only runtime substrate used by the Converge engine to externalize ephemeral context state when scale, availability, or resumability requires it.

It exists to support:

- Engine restarts
- Process crashes
- Long-running Human-in-the-Loop (HITL) waits
- Read-only observation by external tools
- Multi-node execution of a single root intent

It does not participate in reasoning, validation, or convergence.

⸻

## Core Invariant

The ledger is derivative, never authoritative.

This invariant dominates every design choice.

Implications:

- Losing ledger data must not break correctness
- Restarting the ledger must not change outcomes
- The ledger never decides finality
- The ledger never rewrites history
- The ledger never enforces invariants

All semantic authority lives in Converge Core (Rust).

⸻

## What This System Is Not

This service is deliberately not:

- A workflow engine
- A coordination layer
- A message bus
- A pub/sub system
- A consensus system
- A multi-writer database
- A "shared brain" for agents

If a feature implies coordination, consensus, or decision-making, it does not belong here.

⸻

## Relationship to Converge Core

```
┌─────────────────────────────────────────────────────────────┐
│                 Converge Core (Rust)                         │
│                                                             │
│  • Root Intent                                               │
│  • Context semantics                                         │
│  • Convergence logic                                         │
│  • Invariant enforcement                                    │
│  • HITL authority gating                                    │
│                                                             │
│  Single semantic authority                                  │
└───────────────────────────────┬─────────────────────────────┘
                                │ gRPC (optional)
                                ▼
┌─────────────────────────────────────────────────────────────┐
│            Converge Ledger (Elixir / OTP)                    │
│                                                             │
│  • Append-only context entries                               │
│  • Replication & catch-up                                   │
│  • Watch streams (observation only)                          │
│  • Snapshot / restore                                       │
│                                                             │
│  Zero semantic authority                                    │
└─────────────────────────────────────────────────────────────┘
```

Key rule:
The engine can run without the ledger.
The ledger is meaningless without the engine.

⸻

## Single-Writer Model

For any given Root Intent:

- Exactly one Converge engine instance appends entries
- All other consumers are read-only
- Append-only semantics guarantee:
  - No conflicts
  - No merges
  - No consensus protocols

Replication mirrors state; it never resolves meaning.

⸻

## API (Intentionally Minimal)

The ledger exposes exactly five operations:

| Operation | Description |
|-----------|------------|
| Append(context_id, entry) | Append an immutable entry |
| Get(context_id) | Retrieve entries |
| Snapshot(context_id) | Serialize full context |
| Load(context_id, blob) | Restore from snapshot |
| Watch(context_id) | Stream appended entries |

That is the complete API surface.

If more operations seem necessary, the architecture is being violated.

⸻

## Append-Only Semantics

Each context is a linear, monotonic sequence of entries.

- No updates
- No deletes
- No branching
- No conditional writes

Ordering is established solely by sequence number, scoped to a single context.

⸻

## Data Model

### Entry

```elixir
%Entry{
  id: "uuid",
  context_id: "root-intent-1",
  key: "facts" | "proposals" | "evals" | "traces",
  payload: <<binary>>,        # Opaque to the ledger
  sequence: 42,               # Monotonic per context
  appended_at_ns: 1699999999,
  metadata: %{
    "agent_id" => "strategy-agent",
    "cycle" => "5"
  }
}
```

The ledger does not interpret payload.
Schema ownership belongs entirely to Converge Core.

⸻

## Sequence Numbers

- Monotonically increasing per context
- Used for:
  - Ordering
  - Incremental sync (after_sequence)
  - Change detection

No global ordering exists or is required.

⸻

## Snapshots

Snapshots are:

- Portable binary blobs
- Complete representations of a context
- Used for:
  - Engine restart
  - HITL pauses
  - Disaster recovery
  - Moving execution between nodes

Snapshots are mechanical, not semantic.

⸻

## Implementation Choice: Elixir / OTP

Elixir/OTP is used because it provides:

**Strengths**

- In-memory replicated state (Mnesia)
- Lightweight processes
- Fault isolation via supervision trees
- Built-in distribution
- Soft real-time performance

**Explicit Non-Strengths**

- Semantic validation
- Domain logic
- Deterministic reasoning
- Invariant enforcement

Those belong in Rust — by design.

⸻

## Mnesia Schema

```
context_entries
────────────────────────────────────────
id              string (PK)
context_id      string (indexed)
key             string (indexed)
payload         binary
sequence        integer
appended_at_ns  integer
metadata        map

context_sequences
────────────────────────────────────────
context_id      string (PK)
current_seq     integer
```

⸻

## Integrity & Distribution

While the ledger is not authoritative, it must be **trustworthy** and **resilient**.

- **Merkle Trees:** Used for state verification and efficient sync.
- **Lamport Clocks:** Used for causal ordering of distributed events.
- **Gossip Protocol:** Uses Erlang's `:pg` for service discovery.

*See [AGENTS.md](AGENTS.md) for detailed process architecture and implementation patterns.*

⸻

## Supervision Model

```
ConvergeLedger.Supervisor
├── StorageSupervisor (Mnesia)
├── WatchRegistry (GenServer)
├── MnesiaManager (Cluster Healing)
└── GrpcServerSupervisor
    └── ContextService
```

All processes are supervised.
Failures are isolated and restartable.

⸻

## Error Handling

- No exceptions in domain logic
- Explicit result tuples
- Mapping to gRPC at the boundary only

| Domain Error | gRPC Status |
|--------------|-------------|
| :context_not_found | NOT_FOUND |
| :invalid_snapshot | INVALID_ARGUMENT |
| :unsupported_version | INVALID_ARGUMENT |
| Other | INTERNAL |

⸻

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| GRPC_PORT | 50051 | gRPC server port |

⸻

## Evolution Path

**Phase 1 (Current)**

- Single-node
- Mnesia (disc copies)
- gRPC interface

**Phase 2**

- Multi-node replication
- Horizontal read scaling
- Still single writer per context

**Phase 3 (Optional)**

- Geo-replication
- Disaster-tolerant mirrors
- Still append-only, still derivative

At no point does authority move here.

⸻

## Danger Signs (Architectural Alarms)

If you consider adding:

| Feature | Meaning |
|---------|---------|
| Conditional writes | You want coordination |
| Conflict resolution | You want consensus |
| Queries / indexes | You want a database |
| Background jobs | You want workflows |
| Event handlers | You want pub/sub |

Stop.
Re-read the Converge Core architecture.

⸻

## The Golden Rule

Converge converges in Rust.
Anything distributed exists only to remember what already happened.
