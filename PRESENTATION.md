# Tech Talk: Converge Ledger
## Distributed Memory for Agentic Systems

**Theme:** Building a high-performance, fault-tolerant substrate with Elixir/OTP.

---

### 1. The Architectural "Why"
*   **The Context:** Agentic workflows (Converge Core) are long-running, non-deterministic, and computationally expensive.
*   **The Problem:** Distributed agents need a shared, append-only history that survives node failure without introducing the latency of a traditional global consensus (like Raft/Paxos) for every write.
*   **The Solution:** A derivative, single-writer ledger. We trade off global multi-writer consistency for extreme local write performance and eventual cluster-wide availability.

---

### 2. The Tech Stack: Why Elixir/OTP?
*   **Preemptive Concurrency:** The BEAM VM ensures that high-volume gRPC ingestion doesn't starve the background replication processes.
*   **Fault Isolation:** If a specific context's `WatchRegistry` crashes, it doesn't affect other contexts.
*   **Native Distribution:** No sidecars. Nodes find each other via Erlang distribution and replicate data using Mnesia's mesh topology.

---

### 3. Data Integrity & Causal Ordering
*   **Merkle Trees for the Skeptic:** 
    - Every context is a Merkle Tree.
    - We use root-hash comparisons for "Anti-Entropy" (syncing nodes after a partition).
    - *Expert Note:* We implement Bitcoin-style binary trees for deterministic hashing of odd-numbered entry sets.
*   **Lamport Clocks:** 
    - Wall-clock time is a lie in distributed systems.
    - We use Lamport logical clocks to maintain a partial ordering of events, ensuring that "cause" always precedes "effect" in the ledger, regardless of network jitter.

---

### 4. High-Performance Storage: Mnesia
*   **Hybrid Memory/Disk:** Mnesia allows us to keep the "hot" tail of the ledger in RAM for sub-millisecond gRPC reads while asynchronously flushing to disk.
*   **Replication Strategy:** 
    - We use `ram_copies` for speed and `disc_copies` for durability.
    - The `MnesiaManager` (`lib/converge_ledger/cluster/mnesia_manager.ex`) handles the dynamic addition of table copies as the cluster grows or shrinks.

---

### 5. Service Discovery (Gossip-lite)
*   **Process Groups (`:pg`):** 
    - We leverage Erlang's native process groups for zero-config discovery.
    - When a node starts watching a context, it joins a global group. Updates are "gossiped" (multicast) to all members of that group across the cluster.

---

### 6. Critical Invariants (The "Golden Rule")
*   **Derivative, not Authoritative:** The Ledger never validates business logic. It assumes the Core (Rust) has already performed the necessary checks.
*   **Append-Only:** No `UPDATE`, no `DELETE`. This simplifies replication significantly—we only ever care about the "missing tail."

---

### 7. Future: Moving to Phase 3
*   **Geo-Replication:** Leveraging Elixir's distribution to bridge data centers.
*   **Read-Only Mirrors:** Scaling to thousands of observers without impacting the writer's throughput.
