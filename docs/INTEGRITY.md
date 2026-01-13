# Integrity API

Cryptographic integrity verification and causal ordering for the append-only ledger.

## Overview

The converge-ledger provides two integrity primitives:

| Feature | Purpose | Use Case |
|---------|---------|----------|
| **Merkle Trees** | Tamper detection | Verify snapshots haven't been corrupted |
| **Lamport Clocks** | Causal ordering | Order events across distributed contexts |

Both are **automatic** - every `append/4` assigns a Lamport clock and content hash.

## Quick Start

```elixir
alias ConvergeLedger.Storage.Store
alias ConvergeLedger.Entry

# Append - integrity fields assigned automatically
{:ok, entry} = Store.append("my-context", "facts", "payload data")

entry.lamport_clock  # => 1 (causal timestamp)
entry.content_hash   # => <<32 bytes SHA-256>>

# Verify an entry hasn't been tampered with
{:ok, :verified} = Entry.verify_integrity(entry)
```

---

## Lamport Clocks

### What They Solve

Wall clocks lie. In distributed systems, machine clocks drift and can't establish causality. Lamport clocks provide a **logical timestamp** that guarantees:

> If event A influenced event B, then `clock(A) < clock(B)`

### Automatic Assignment

Every `append/4` ticks the context's Lamport clock:

```elixir
{:ok, e1} = Store.append("ctx", "facts", "first")
{:ok, e2} = Store.append("ctx", "facts", "second")
{:ok, e3} = Store.append("ctx", "facts", "third")

e1.lamport_clock  # => 1
e2.lamport_clock  # => 2
e3.lamport_clock  # => 3
```

### Cross-Context Causality

When receiving data from another context, use `append_with_received_time/5` to maintain causal ordering:

```elixir
# Context A creates an entry
{:ok, a_entry} = Store.append("context-a", "facts", "created by A")
# a_entry.lamport_clock => 1

# Context B receives A's entry and creates a derived entry
{:ok, b_entry} = Store.append_with_received_time(
  "context-b",
  "facts",
  "derived from A",
  a_entry.lamport_clock  # Pass the received timestamp
)
# b_entry.lamport_clock => 2 (guaranteed > a_entry.lamport_clock)

# Causal ordering is preserved
LamportClock.happened_before?(a_entry.lamport_clock, b_entry.lamport_clock)
# => true
```

### Query Current Time

```elixir
{:ok, time} = Store.current_lamport_time("my-context")
# => 42
```

### Direct API

For advanced use cases, use `ConvergeLedger.Integrity.LamportClock` directly:

```elixir
alias ConvergeLedger.Integrity.LamportClock

clock = LamportClock.new()

# Local event
{clock, t1} = LamportClock.tick(clock)  # t1 = 1

# Receiving from another node
{clock, t2} = LamportClock.update(clock, 100)  # t2 = 101 (max + 1)

# Compare timestamps
LamportClock.happened_before?(t1, t2)  # => true
LamportClock.compare(t1, t2)           # => :lt

# Merge clocks from multiple sources
merged = LamportClock.merge(clock_a, clock_b)  # Takes max
```

---

## Content Hashes

### What They Solve

Detect if an entry has been modified after creation. Each entry stores a SHA-256 hash of its content.

### Automatic Assignment

Every `append/4` computes and stores the content hash:

```elixir
{:ok, entry} = Store.append("ctx", "facts", "payload")

entry.content_hash
# => <<199, 158, 253, 75, ...>> (32 bytes)
```

### Verify Integrity

```elixir
alias ConvergeLedger.Entry

# Verify an entry
{:ok, :verified} = Entry.verify_integrity(entry)

# Check if entry has integrity fields
Entry.has_integrity?(entry)  # => true
```

### Tamper Detection

```elixir
{:ok, entry} = Store.append("ctx", "facts", "original")

# Someone tampers with the entry
tampered = %{entry | payload: "malicious data"}

# Verification fails
{:error, :hash_mismatch} = Entry.verify_integrity(tampered)
```

### What's Hashed

The content hash covers these fields:
- `context_id`
- `key`
- `payload`
- `sequence`
- `appended_at_ns`

**Not included:** `metadata`, `lamport_clock`, `content_hash`, `id`

---

## Merkle Trees

### What They Solve

Efficiently verify the integrity of a **collection** of entries. A single 32-byte root hash represents the integrity of thousands of entries.

### Snapshot Verification

Snapshots automatically include a Merkle root:

```elixir
# Create snapshot
{:ok, blob, seq, meta} = Store.snapshot("my-context")

meta.merkle_root  # => "a1b2c3d4..." (hex string)
meta.version      # => 2 (version 2 includes Merkle root)

# Load with integrity verification (default: enabled)
{:ok, count, seq} = Store.load("target-context", blob)

# Or explicitly verify
{:ok, count, seq} = Store.load("target-context", blob, verify_integrity: true)

# Skip verification (not recommended)
{:ok, count, seq} = Store.load("target-context", blob, verify_integrity: false)
```

### Direct API

For advanced use cases, use `ConvergeLedger.Integrity.MerkleTree` directly:

```elixir
alias ConvergeLedger.Integrity.MerkleTree

# Compute root from entries
root = MerkleTree.compute_root_from_entries(entries)

# Verify entries against a known root
MerkleTree.verify_entries(entries, expected_root)
# => true | false

# Generate proof that entry exists (without revealing other entries)
hashes = Enum.map(entries, &MerkleTree.hash_entry/1)
root = MerkleTree.compute_root(hashes)

{:ok, proof} = MerkleTree.generate_proof(hashes, index)
# proof is O(log n) hashes

# Verify proof
leaf_hash = Enum.at(hashes, index)
MerkleTree.verify_proof(leaf_hash, proof, root)
# => true

# Convert to/from hex
MerkleTree.to_hex(root)      # => "a1b2c3d4..."
MerkleTree.from_hex(hex)     # => {:ok, <<bytes>>}
MerkleTree.to_short_hex(root) # => "a1b2c3d4e5f6g7h8" (first 16 chars)
```

### Merkle Proofs

Prove an entry exists without revealing all entries:

```elixir
# You have 10,000 entries
entries = get_all_entries()
hashes = Enum.map(entries, &MerkleTree.hash_entry/1)
root = MerkleTree.compute_root(hashes)

# Generate proof for entry at index 42
{:ok, proof} = MerkleTree.generate_proof(hashes, 42)

# Proof contains only ~14 hashes (log2(10000))
length(proof)  # => 14

# Someone else can verify entry 42 exists, given only:
# - The entry's hash
# - The proof (14 hashes)
# - The root hash
MerkleTree.verify_proof(entry_42_hash, proof, root)
# => true
```

---

## Patterns

### Verify All Retrieved Entries

```elixir
{:ok, entries, _} = Store.get("my-context")

Enum.each(entries, fn entry ->
  case Entry.verify_integrity(entry) do
    {:ok, :verified} -> :ok
    {:ok, :no_hash} -> Logger.warn("Legacy entry without hash")
    {:error, :hash_mismatch} -> raise "Tampered entry detected!"
  end
end)
```

### Causal Chain Across Workflows

```elixir
# Workflow A creates initial state
{:ok, a} = Store.append("workflow-a", "state", "initial")

# Workflow B receives and extends
{:ok, b} = Store.append_with_received_time(
  "workflow-b", "state", "extended", a.lamport_clock
)

# Workflow C receives from B and finalizes
{:ok, c} = Store.append_with_received_time(
  "workflow-c", "state", "finalized", b.lamport_clock
)

# Causal chain: a < b < c
[a, b, c]
|> Enum.map(& &1.lamport_clock)
|> Enum.chunk_every(2, 1, :discard)
|> Enum.all?(fn [prev, next] -> prev < next end)
# => true
```

### Sort by Causal Order

```elixir
# Entries may arrive out of order
entries = get_entries_from_multiple_sources()

# Sort by Lamport clock for consistent causal ordering
sorted = Enum.sort_by(entries, & &1.lamport_clock)
```

---

## Error Handling

### Entry.verify_integrity/1

| Return | Meaning |
|--------|---------|
| `{:ok, :verified}` | Hash matches - entry is intact |
| `{:ok, :no_hash}` | Legacy entry without content_hash |
| `{:error, :hash_mismatch}` | Entry has been tampered with |

### Store.load/3

| Return | Meaning |
|--------|---------|
| `{:ok, count, seq}` | Loaded successfully |
| `{:error, :invalid_snapshot_format}` | Blob is corrupted |
| `{:error, :integrity_verification_failed}` | Merkle root doesn't match |
| `{:error, :context_already_exists}` | Context has entries (with `fail_if_exists: true`) |

### MerkleTree.generate_proof/2

| Return | Meaning |
|--------|---------|
| `{:ok, proof}` | Valid proof generated |
| `{:error, :invalid_index}` | Index out of bounds |

---

## Performance

| Operation | Complexity | 10K entries |
|-----------|------------|-------------|
| `append/4` | O(1) | ~0.1ms |
| `compute_root_from_entries/1` | O(n) | ~500ms |
| `generate_proof/2` | O(n) | ~100ms |
| `verify_proof/3` | O(log n) | ~0.01ms |
| `verify_integrity/1` | O(1) | ~0.01ms |

---

## Design Notes

### Why Lamport Clocks (not Vector Clocks)?

Lamport clocks are simpler and sufficient for our use case:
- We need **causal ordering**, not concurrent conflict detection
- The Rust engine is the single semantic authority
- Simpler state: just one integer per context

### Why Content Hash Excludes Metadata?

Metadata is auxiliary information (tags, annotations) that may legitimately change without affecting the semantic content. The hash covers the **immutable semantic content**.

### Why Recompute Hash on Context Change?

When loading a snapshot into a different context, the `context_id` changes. Since `context_id` is part of the hash, we recompute to maintain verifiability in the new context.
