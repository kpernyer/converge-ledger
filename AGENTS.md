# Agents & Process Architecture

This document details the active runtime components ("Agents") and data integrity structures within `ConvergeLedger`. It supplements [ARCHITECTURE.md](ARCHITECTURE.md) by focusing on implementation patterns and OTP behaviors.

## Core Philosophy

We follow the **"Functional Core, Imperative Shell"** pattern:
- **Pure Logic:** Complex logic (Merkle trees, Lamport clocks) is implemented in pure functional modules with no side effects.
- **State & Side Effects:** OTP processes (GenServers) are kept thin, responsible only for holding state, coordinating resources, or interfacing with the system (IO, Network).

## OTP Servers (Agents)

### 1. WatchRegistry
**Role:** Pub/Sub mechanism for ledger updates.
**Implementation:** `GenServer`
**File:** `lib/converge_ledger/watch_registry.ex`

- **Responsibility:** Manages dynamic lists of subscribers (PIDs) interested in specific context updates.
- **Failure Handling:** Uses `Process.monitor/1` to detect subscriber crashes and automatically clean up stale subscriptions, preventing memory leaks.
- **Pattern:** Registry / Event Dispatcher. It decouples the writer (Store) from the readers (gRPC streams).

### 2. MnesiaManager
**Role:** Cluster topology and replication manager.
**Implementation:** `GenServer`
**File:** `lib/converge_ledger/cluster/mnesia_manager.ex`

- **Responsibility:** Monitors node up/down events (`:net_kernel.monitor_nodes`).
- **Behavior:**
  - On node join: Connects Mnesia (`:mnesia.change_config`) and initiates table replication.
  - Ensures data redundancy by adding local table copies dynamically.
- **Pattern:** Manager / Daemon. It ensures the storage layer adapts to the changing cluster topology without manual intervention.

### 3. Service Discovery
**Role:** Location transparency for context services.
**Implementation:** Wrapper around Erlang's `:pg` (Process Groups).
**File:** `lib/converge_ledger/discovery.ex`

- **Mechanism:** "Gossip" is handled by the underlying Erlang distribution layer and the `:pg` module.
- **Function:** Allows processes to join "groups" identified by a `context_id`.
- **Usage:** Enables broadcasting messages to all nodes interested in a specific context without knowing their physical location.

## Data Integrity & Ordering

### Merkle Trees
**Role:** Cryptographic integrity and state verification.
**Implementation:** Pure Functional Module
**File:** `lib/converge_ledger/integrity/merkle_tree.ex`

- **Algorithm:** SHA-256 binary Merkle Tree.
- **Feature:** "Bitcoin-style" handling of odd nodes (duplicating the single element).
- **Use Cases:**
  - **Snapshot Verification:** Ensures loaded data hasn't been tampered with.
  - **Sync:** Efficiently detects differences between replicas by comparing root hashes.
  - **Proofs:** Generates inclusion proofs to verify a specific entry exists in the tree without retrieving the whole dataset.

### Lamport Clocks
**Role:** Causal ordering of events in a distributed system.
**Implementation:** Pure Functional Struct
**File:** `lib/converge_ledger/integrity/lamport_clock.ex`

- **Concept:** Logical time `T` where if event `A` causes `B`, then `T(A) < T(B)`.
- **Operations:**
  - `tick/1`: Increments local time before an event.
  - `update/2`: Merges local time with received time (`max(local, received) + 1`).
- **Invariant:** Ensures that even across distributed nodes, we can reason about the causal sequence of operations, independent of wall-clock skew.

## Supervision Tree

The system is structured as a hierarchical supervision tree to ensure fault tolerance:

```
ConvergeLedger.Supervisor
├── StorageSupervisor (Mnesia management)
├── WatchRegistry (Subscriber state)
├── MnesiaManager (Cluster healing)
└── GrpcServerSupervisor (External API)
```

## Best Practices Checklist

- [x] **Separation of Concerns:** `Integrity` modules are pure; `Cluster` modules manage state.
- [x] **Fault Tolerance:** All processes are supervised. Crash isolation is enforced.
- [x] **Resource Management:** Monitors are used to clean up resources (subscriptions) upon client failure.
- [x] **Distribution:** Standard OTP mechanisms (`:pg`, `:mnesia`) are preferred over custom implementation for clustering and discovery.
