# Execution Plan

## 1. Immediate Next Steps: Solidify Phase 2 (Multi-Node)

The codebase currently contains the scaffolding for multi-node operations (`MnesiaManager`, `Discovery`). The next steps focus on verifying and hardening these features.

- [ ] **Cluster Formation Tests**:
    - Create a test suite that spawns multiple nodes (using `LocalCluster` or similar in test/helper).
    - Verify `MnesiaManager` correctly replicates tables on join.
    - Verify `Discovery` correctly identifies peers.
- [ ] **Replication Verification**:
    - Test that an entry appended on Node A is readable on Node B.
    - Test that `WatchRegistry` on Node B receives updates from writes on Node A.
- [ ] **Resilience Testing**:
    - Simulate node crashes (kill a node) and verify the cluster recovers.
    - Verify no data loss if at least one node holding the replica survives.

## 2. Documentation & artifacts

- [x] Create `AGENTS.md` to document runtime behavior.
- [ ] Update `ARCHITECTURE.md` to reflect current implementation details (Integrity, Supervision).
- [ ] Generate "Tech Talk" Presentation (see below).

---

# Presentation: "Converge Ledger — The Memory of the System"

**Target Audience:** Distributed Systems Engineers, Architects.
**Theme:** High-performance, fault-tolerant state management using Elixir/OTP.

## Slide 1: The Problem
- **Context:** Large-scale "Agentic" systems need memory.
- **Constraint:** Agents crash. Workflows pause. Reasoning is expensive.
- **Naive Solution:** "Just use Postgres."
- **Why it fails:** Polling, centralized bottlenecks, complexity in reactive systems.

## Slide 2: The Solution — "Functional Core, Imperative Shell"
- **Split Brain:**
    - **Converge Core (Rust):** The Brain. Semantic authority, logic, rules.
    - **Converge Ledger (Elixir):** The Memory. Derivative, append-only, fault-tolerant.
- **Key Invariant:** "The Ledger never decides. It only remembers."

## Slide 3: The Architecture (Visual)
- Show the Single-Writer model.
- **Elixir/OTP Role:**
    - `Mnesia`: Distributed, in-memory soft-real-time storage.
    - `GenServer`: Isolated failure domains.
    - `Distribution`: Native clustering (no sidecars needed).

## Slide 4: Trust but Verify (Integrity)
- **Merkle Trees:**
    - Every context has a cryptographic root hash.
    - Instant sync/diff detection (O(log n)).
    - Tamper evidence.
- **Lamport Clocks:**
    - Causal ordering independent of wall-clock time.
    - Solves "who did what when" in a distributed system.

## Slide 5: The "Gossip" (Discovery)
- How nodes find each other (`lib/converge_ledger/discovery.ex`).
- Using Erlang's `:pg` for process groups.
- Zero-config clustering.

## Slide 6: Demo / Code Walkthrough
- Show `AGENTS.md` (Process architecture).
- Show a snippet of `merkle_tree.ex` (Functional purity).
- Show `mnesia_manager.ex` (Cluster self-healing).

## Slide 7: Q&A
- "Why not Kafka?" (Too heavy, we need state *snapshotting*).
- "Why not Redis?" (We need structured integrity & behavior).
