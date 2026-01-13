# Converge Ledger
## The Memory of the System

**A Distributed, Append-Only Runtime Substrate for Agentic Systems**

*Target Audience: Distributed Systems Engineers, Architects*

---

# Slide 1: The Problem

## Large-Scale Agentic Systems Need Memory

**Context:**
- AI agents execute complex, multi-step workflows
- Reasoning is expensive (LLM calls = seconds, not milliseconds)
- Human-in-the-loop gates create unpredictable pauses

**Constraints:**
- Agents crash. Workflows pause. Progress must survive.
- Multiple observers need real-time visibility
- Recovery must be fast (not recompute-from-scratch)

**Naive Solution:** "Just use Postgres."

**Why It Fails:**
- Polling creates latency and load
- Centralized bottleneck for reactive systems
- No native clustering or real-time streaming
- Mismatch between relational model and append-only semantics

---

# Slide 2: The Architecture Principle

## "Functional Core, Imperative Shell"

```
┌─────────────────────────────────────────────────────────────┐
│               Converge Core (Rust — Authority)              │
│                                                             │
│  - Root Intent                                              │
│  - Convergence logic                                        │
│  - Invariant enforcement                                    │
│  - HITL authority gating                                    │
│                                                             │
│  DECIDES what happens                                       │
└───────────────────────────────┬─────────────────────────────┘
                                │ gRPC
                                ▼
┌─────────────────────────────────────────────────────────────┐
│            Converge Ledger (Elixir — Substrate)             │
│                                                             │
│  - Append-only context entries                              │
│  - Replication & catch-up                                   │
│  - Watch streams (observation only)                         │
│  - Snapshot / restore                                       │
│                                                             │
│  REMEMBERS what happened                                    │
└─────────────────────────────────────────────────────────────┘
```

**Key Invariant:**

> "The Ledger never decides. It only remembers."

---

# Slide 3: The Single-Writer Model

## Why No Coordination?

For any given Root Intent:

| Property | Guarantee |
|----------|-----------|
| **Single Writer** | Exactly one Converge engine appends entries |
| **Multiple Readers** | Any number of observers (tools, dashboards, other engines) |
| **Append-Only** | No updates, deletes, or overwrites |

**What This Eliminates:**
- No conflicts
- No merge logic
- No consensus protocols (Raft, Paxos)
- No distributed transactions

**Result:** Replication mirrors state; it never resolves meaning.

---

# Slide 4: Why Elixir/OTP?

## The Right Tool for the Job

| OTP Feature | How We Use It |
|-------------|---------------|
| **Mnesia** | Distributed, in-memory, soft-real-time storage |
| **GenServer** | Isolated failure domains (crash one, not all) |
| **Supervisors** | Automatic restart, self-healing |
| **:net_kernel** | Native clustering (no sidecars needed) |
| **:pg (Process Groups)** | Zero-config service discovery |

**What We Explicitly Avoid:**
- Semantic validation (belongs in Rust)
- Domain logic (belongs in Rust)
- Invariant enforcement (belongs in Rust)

**The Philosophy:**
- Elixir = plumbing (fast, reliable, distributed)
- Rust = reasoning (correct, deterministic, authoritative)

---

# Slide 5: The API (Minimal by Design)

## Five Operations. That's It.

| Operation | Purpose |
|-----------|---------|
| `Append(context_id, entry)` | Add an immutable entry |
| `Get(context_id)` | Retrieve entries |
| `Snapshot(context_id)` | Serialize full context |
| `Load(context_id, blob)` | Restore from snapshot |
| `Watch(context_id)` | Stream new entries |

**Deliberately Missing:**
- Updates
- Deletes
- Transactions
- Branching
- Conditional writes
- Queries / Indexes

**If you need those, you're using the wrong system.**

---

# Slide 6: Trust but Verify — Merkle Trees

## Cryptographic Integrity

```elixir
defmodule ConvergeLedger.Integrity.MerkleTree do
  @spec hash(binary()) :: hash()
  def hash(content), do: :crypto.hash(:sha256, content)

  @spec combine(hash(), hash()) :: hash()
  def combine(left, right), do: hash(left <> right)

  @spec compute_root([hash()]) :: hash()
  def compute_root([single]), do: combine(single, single)
  def compute_root(hashes), do: build_tree_level(hashes)
end
```

**Use Cases:**
- **Snapshot verification:** Detect corruption before loading
- **Efficient sync:** O(log n) diff detection between replicas
- **Tamper evidence:** Any change = different root hash
- **Audit proofs:** Prove entry exists without revealing all entries

**Performance:**

| Operation | Complexity | 10K entries |
|-----------|------------|-------------|
| `compute_root` | O(n) | ~500ms |
| `generate_proof` | O(n) | ~100ms |
| `verify_proof` | O(log n) | ~0.01ms |

---

# Slide 7: Causal Ordering — Lamport Clocks

## Solving "Who Did What When"

**The Problem:** Wall clocks lie. Machine clocks drift.

**The Solution:** Logical time.

```elixir
defmodule ConvergeLedger.Integrity.LamportClock do
  defstruct time: 0

  # Local event: increment
  def tick(%{time: t} = clock) do
    new_time = t + 1
    {%{clock | time: new_time}, new_time}
  end

  # Received message: max + 1
  def update(%{time: local} = clock, received) do
    new_time = max(local, received) + 1
    {%{clock | time: new_time}, new_time}
  end
end
```

**The Guarantee:**

> If event A happened-before event B, then `clock(A) < clock(B)`

**Cross-Context Causality:**
```elixir
# Context A creates entry
{:ok, a} = Store.append("ctx-a", "facts", "data")
# a.lamport_clock = 1

# Context B receives A's data and extends
{:ok, b} = Store.append_with_received_time("ctx-b", "facts", "derived", 1)
# b.lamport_clock = 2 (guaranteed > a)

# Causal chain preserved across distributed contexts
```

---

# Slide 8: Zero-Config Discovery

## How Nodes Find Each Other

```elixir
defmodule ConvergeLedger.Discovery do
  # Register as serving a context
  def join(context_id) do
    :pg.join({:context, context_id}, self())
  end

  # Find all servers for a context (cluster-wide)
  def members(context_id) do
    :pg.get_members({:context, context_id})
  end

  # Broadcast to all interested parties
  def broadcast(context_id, message) do
    members(context_id)
    |> Enum.each(fn pid -> send(pid, message) end)
  end
end
```

**What `:pg` Provides:**
- Process groups across the Erlang cluster
- Automatic gossip via Erlang distribution
- No central registry
- Members discovered dynamically

**No sidecars. No service mesh. No configuration.**

---

# Slide 9: Cluster Self-Healing

## Automatic Topology Management

```elixir
defmodule ConvergeLedger.Cluster.MnesiaManager do
  use GenServer

  def init(_opts) do
    # Subscribe to cluster events
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  def handle_info({:nodeup, node}, state) do
    # New node joined — replicate data
    :mnesia.change_config(:extra_db_nodes, [node])
    replicate_tables()
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    # Node left — Mnesia handles failover
    {:noreply, state}
  end
end
```

**Behavior:**
- On node join: Connect Mnesia, replicate tables
- On node leave: Automatic failover (if replicas exist)
- No manual intervention required

---

# Slide 10: The Data Model

## Context Entries

```
┌─────────────────────────────────────────────────────────────┐
│ Context: growth-strategy-001                                │
├──────────┬────────────┬─────────────────────────────────────┤
│ seq=1    │ facts      │ market_size: 2.4B                   │
│ seq=2    │ intents    │ objective: increase_demand          │
│ seq=3    │ traces     │ agent:analyst started               │
│ seq=4    │ proposals  │ strategy: partnership_model         │
│ seq=5    │ evals      │ confidence: 0.73                    │
│   ⋮      │    ⋮       │        ⋮                            │
└─────────────────────────────────────────────────────────────┘
```

**Entry Structure:**
```elixir
%Entry{
  id: "uuid",
  context_id: "root-intent-1",
  key: "facts" | "proposals" | "evals" | "traces",
  payload: <<binary>>,       # Opaque to the ledger
  sequence: 42,              # Monotonic per context
  lamport_clock: 17,         # Causal timestamp
  content_hash: <<32 bytes>>, # SHA-256
  appended_at_ns: 1699999999,
  metadata: %{}
}
```

---

# Slide 11: Supervision Tree

## Fault Isolation

```
ConvergeLedger.Supervisor
├── StorageSupervisor
│   └── Mnesia initialization
├── WatchRegistry (GenServer)
│   └── Subscriber management
├── MnesiaManager (GenServer)
│   └── Cluster topology
└── GrpcServerSupervisor
    └── External API
```

**Properties:**
- Each component has isolated failure domain
- Crash in WatchRegistry doesn't affect storage
- Restart strategy: one-for-one (restart failed child only)
- Resource cleanup via `Process.monitor/1`

---

# Slide 12: When to Use This

## Good Fit

- Distributed observation of running convergence
- Fast restart without recomputation
- External tooling (debuggers, dashboards)
- Large or long-running contexts
- Multi-node execution per job
- HITL pauses lasting minutes/hours/days

## Bad Fit

- Replacement for Converge Core
- Agent communication layer
- General-purpose database
- Event sourcing system
- Message queue

---

# Slide 13: Q&A — Anticipated Questions

## "Why not Kafka?"

- Too heavy for our use case
- We need state **snapshotting**, not just event streaming
- Kafka is for pub/sub; we need context recovery
- No built-in integrity verification

## "Why not Redis?"

- No native clustering that handles replication
- No structured integrity (Merkle trees)
- No causal ordering
- Memory-only (or complex persistence setup)

## "Why not Postgres?"

- Polling, not streaming
- No native clustering
- Append-only requires fighting the relational model
- No process supervision / fault isolation

## "Why not just in-memory in Rust?"

- We do that for small contexts
- Ledger is for: large contexts, distributed observation, fast recovery
- The Rust engine can always regenerate — ledger is for operational convenience

---

# Slide 14: The Contract

## What This System Guarantees

**Nothing in this system may influence convergence semantics.**

If a proposed feature violates that rule, it does not belong here.

**The Ledger:**
- Never decides finality
- Never rewrites history
- Never enforces invariants
- Never participates in reasoning

**All semantic authority lives in Converge Core (Rust).**

---

# Slide 15: Architecture Danger Signs

## When to Stop and Re-Read the Docs

| If you want... | You probably need... |
|----------------|---------------------|
| Conditional writes | Coordination layer |
| Conflict resolution | Consensus protocol |
| Complex queries | A real database |
| Background jobs | Workflow engine |
| Event handlers | Pub/sub system |

**This is not a general-purpose distributed system.**
**It's a specialized memory layer for a specific architecture.**

---

# Summary

## Key Takeaways

1. **Separation of concerns:** Rust decides, Elixir remembers
2. **Single-writer model:** No coordination needed
3. **Append-only:** No conflicts, no merges
4. **Cryptographic integrity:** Merkle trees + Lamport clocks
5. **OTP primitives:** Built on battle-tested infrastructure
6. **Minimal API:** Five operations, no more

> Converge converges in Rust.
> Anything distributed exists only to remember what already happened.

---

# Resources

- **README.md** — Overview and philosophy
- **ARCHITECTURE.md** — Detailed design decisions
- **AGENTS.md** — Process architecture and OTP patterns
- **docs/INTEGRITY.md** — Merkle trees and Lamport clocks API

---

*Converge Ledger — Optional, Derivative, Replaceable*
