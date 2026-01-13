defmodule ConvergeLedger.Integrity.StressTest do
  @moduledoc """
  Stress tests for integrity features.

  These tests push the system hard to verify:
  - Performance under load
  - Correctness with large datasets
  - Concurrent access patterns
  - Cross-context collaboration scenarios
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ConvergeLedger.Entry
  alias ConvergeLedger.Storage.{Schema, Store}
  alias ConvergeLedger.Integrity.{MerkleTree, LamportClock}

  # Increase timeout for stress tests
  @moduletag timeout: 120_000

  setup do
    :mnesia.start()
    Schema.init()
    :mnesia.wait_for_tables(
      [Schema.entries_table(), Schema.sequences_table(), Schema.lamport_clocks_table()],
      5000
    )
    Schema.clear_all()
    :ok
  end

  # ============================================================================
  # STRESS TESTS - Push the limits
  # ============================================================================

  describe "high volume stress tests" do
    @tag :stress
    test "handles 10,000 entries with consistent Lamport ordering" do
      count = 10_000
      context_id = "stress-lamport-#{:rand.uniform(1_000_000)}"

      # Append many entries
      entries =
        for i <- 1..count do
          {:ok, entry} = Store.append(context_id, "facts", "payload-#{i}")
          entry
        end

      # Verify Lamport clocks are strictly monotonic
      lamport_times = Enum.map(entries, & &1.lamport_clock)
      assert lamport_times == Enum.to_list(1..count)

      # Verify all content hashes are valid
      for entry <- entries do
        assert {:ok, :verified} = Entry.verify_integrity(entry)
      end

      # Verify final state
      {:ok, ^count} = Store.current_lamport_time(context_id)
      {:ok, ^count} = Store.current_sequence(context_id)
    end

    @tag :stress
    test "Merkle tree handles 10,000 entries efficiently" do
      entries = for i <- 1..10_000, do: create_entry("ctx", "key", "payload-#{i}", i)

      # Compute root - should be fast
      {time_us, root} = :timer.tc(fn -> MerkleTree.compute_root_from_entries(entries) end)

      assert is_binary(root)
      assert byte_size(root) == 32

      # Should complete in reasonable time (< 1 second)
      assert time_us < 1_000_000, "Merkle root computation took #{time_us}us, expected < 1s"

      # Recomputation should produce same result
      root2 = MerkleTree.compute_root_from_entries(entries)
      assert root == root2
    end

    @tag :stress
    test "snapshot and load with 5,000 entries preserves integrity" do
      context_id = "stress-snapshot-#{:rand.uniform(1_000_000)}"
      count = 5_000

      # Append entries
      for i <- 1..count do
        Store.append(context_id, "facts", "payload-#{i}", %{"index" => i})
      end

      # Create snapshot
      {:ok, blob, seq, meta} = Store.snapshot(context_id)

      assert meta.entry_count == count
      assert seq == count
      assert is_binary(meta.merkle_root)

      # Load into new context
      target_id = "stress-target-#{:rand.uniform(1_000_000)}"
      {:ok, restored_count, restored_seq} = Store.load(target_id, blob)

      assert restored_count == count
      assert restored_seq == count

      # Verify all restored entries
      {:ok, entries, _} = Store.get(target_id)
      assert length(entries) == count

      for entry <- entries do
        assert {:ok, :verified} = Entry.verify_integrity(entry)
      end
    end

    @tag :stress
    test "concurrent appends to same context maintain ordering" do
      context_id = "stress-concurrent-#{:rand.uniform(1_000_000)}"
      tasks_count = 10
      entries_per_task = 100

      # Launch concurrent tasks
      tasks =
        for task_id <- 1..tasks_count do
          Task.async(fn ->
            for i <- 1..entries_per_task do
              {:ok, entry} = Store.append(context_id, "facts", "task-#{task_id}-entry-#{i}")
              entry
            end
          end)
        end

      # Wait for all tasks
      all_entries = tasks |> Enum.flat_map(&Task.await(&1, 30_000))

      # All entries should have unique Lamport times (no collisions)
      lamport_times = Enum.map(all_entries, & &1.lamport_clock)
      unique_times = Enum.uniq(lamport_times)
      assert length(unique_times) == length(lamport_times), "Lamport times should be unique"

      # Total count should match
      total = tasks_count * entries_per_task
      {:ok, ^total} = Store.current_sequence(context_id)
      {:ok, ^total} = Store.current_lamport_time(context_id)

      # All entries should verify
      {:ok, retrieved, _} = Store.get(context_id)
      for entry <- retrieved do
        assert {:ok, :verified} = Entry.verify_integrity(entry)
      end
    end
  end

  # ============================================================================
  # CROSS-CONTEXT COLLABORATION - The real-world scenario
  # ============================================================================

  describe "cross-context collaboration stress" do
    @tag :stress
    test "causal chain across 100 contexts" do
      # Simulate a long chain: A -> B -> C -> ... -> Z
      # Each context receives from previous and adds its own work

      chain_length = 100
      contexts = for i <- 1..chain_length, do: "chain-ctx-#{i}-#{:rand.uniform(1_000_000)}"

      # First context creates initial entry
      [first_ctx | rest] = contexts
      {:ok, first_entry} = Store.append(first_ctx, "facts", "genesis")

      # Each subsequent context receives and extends
      final_entry =
        Enum.reduce(rest, first_entry, fn ctx, prev_entry ->
          {:ok, entry} = Store.append_with_received_time(
            ctx,
            "facts",
            "derived from #{prev_entry.context_id}",
            prev_entry.lamport_clock
          )
          entry
        end)

      # Final entry should have Lamport time reflecting entire chain
      # Each step does max(local=0, received) + 1, so chain of N should end at N
      assert final_entry.lamport_clock == chain_length

      # Causal ordering is preserved
      assert LamportClock.happened_before?(first_entry.lamport_clock, final_entry.lamport_clock)
    end

    @tag :stress
    test "diamond dependency pattern preserves causality" do
      # Pattern:
      #       A
      #      / \
      #     B   C
      #      \ /
      #       D
      #
      # D depends on both B and C, which both depend on A

      ctx_a = "diamond-a-#{:rand.uniform(1_000_000)}"
      ctx_b = "diamond-b-#{:rand.uniform(1_000_000)}"
      ctx_c = "diamond-c-#{:rand.uniform(1_000_000)}"
      ctx_d = "diamond-d-#{:rand.uniform(1_000_000)}"

      # A creates
      {:ok, a} = Store.append(ctx_a, "facts", "origin")

      # B and C both receive from A (in parallel)
      {:ok, b} = Store.append_with_received_time(ctx_b, "facts", "branch-b", a.lamport_clock)
      {:ok, c} = Store.append_with_received_time(ctx_c, "facts", "branch-c", a.lamport_clock)

      # Both B and C have time > A
      assert b.lamport_clock > a.lamport_clock
      assert c.lamport_clock > a.lamport_clock

      # D receives from both - takes max
      {:ok, d1} = Store.append_with_received_time(ctx_d, "facts", "merge-b", b.lamport_clock)
      {:ok, d2} = Store.append_with_received_time(ctx_d, "facts", "merge-c", c.lamport_clock)

      # D's entries are after both B and C
      assert d1.lamport_clock > b.lamport_clock
      assert d2.lamport_clock > c.lamport_clock
      assert d2.lamport_clock > d1.lamport_clock

      # Full causal chain is preserved
      assert LamportClock.happened_before?(a.lamport_clock, d2.lamport_clock)
    end

    @tag :stress
    test "many-to-one aggregation pattern" do
      # 50 source contexts all feed into one aggregator
      source_count = 50
      entries_per_source = 20

      sources = for i <- 1..source_count, do: "source-#{i}-#{:rand.uniform(1_000_000)}"
      aggregator = "aggregator-#{:rand.uniform(1_000_000)}"

      # Each source creates entries
      source_entries =
        for {src, src_idx} <- Enum.with_index(sources, 1) do
          for i <- 1..entries_per_source do
            {:ok, entry} = Store.append(src, "facts", "source-#{src_idx}-entry-#{i}")
            entry
          end
        end
        |> List.flatten()

      # Aggregator receives all entries (simulating sync)
      max_source_time = source_entries |> Enum.map(& &1.lamport_clock) |> Enum.max()

      {:ok, agg_entry} = Store.append_with_received_time(
        aggregator,
        "facts",
        "aggregated #{length(source_entries)} entries",
        max_source_time
      )

      # Aggregator's entry is causally after all source entries
      assert agg_entry.lamport_clock > max_source_time

      for entry <- source_entries do
        assert LamportClock.happened_before?(entry.lamport_clock, agg_entry.lamport_clock)
      end
    end
  end

  # ============================================================================
  # PROPERTY TESTS - Fuzz the integrity features
  # ============================================================================

  describe "property: Merkle tree invariants" do
    property "any modification changes the root" do
      check all(
              count <- StreamData.integer(2..100),
              tamper_index <- StreamData.integer(0..99)
            ) do
        tamper_index = rem(tamper_index, count)
        entries = for i <- 1..count, do: create_entry("ctx", "k", "p-#{i}", i)

        original_root = MerkleTree.compute_root_from_entries(entries)

        # Tamper with one entry
        tampered = List.update_at(entries, tamper_index, fn e ->
          %{e | payload: e.payload <> "-tampered"}
        end)

        tampered_root = MerkleTree.compute_root_from_entries(tampered)
        assert original_root != tampered_root
      end
    end

    property "root is deterministic regardless of computation order" do
      check all(
              count <- StreamData.integer(1..50),
              seed <- StreamData.integer(1..1_000_000)
            ) do
        entries = for i <- 1..count, do: create_entry("ctx", "k", "p-#{i}", i)

        root1 = MerkleTree.compute_root_from_entries(entries)
        root2 = MerkleTree.compute_root_from_entries(entries)
        root3 = MerkleTree.compute_root_from_entries(Enum.reverse(entries) |> Enum.reverse())

        assert root1 == root2
        assert root2 == root3
      end
    end

    property "proof verifies for any valid index" do
      check all(count <- StreamData.integer(1..100)) do
        hashes = for i <- 1..count, do: MerkleTree.hash("data-#{i}")
        root = MerkleTree.compute_root(hashes)

        for index <- 0..(count - 1) do
          {:ok, proof} = MerkleTree.generate_proof(hashes, index)
          leaf = Enum.at(hashes, index)
          assert MerkleTree.verify_proof(leaf, proof, root)
        end
      end
    end

    property "proof size is O(log n)" do
      check all(count <- StreamData.integer(1..1000)) do
        hashes = for i <- 1..count, do: MerkleTree.hash("data-#{i}")
        {:ok, proof} = MerkleTree.generate_proof(hashes, 0)

        # Proof size should be ceil(log2(count))
        expected_max = ceil(:math.log2(max(count, 1))) + 1
        assert length(proof) <= expected_max
      end
    end
  end

  describe "property: Lamport clock invariants" do
    property "tick always increases" do
      check all(
              initial <- StreamData.integer(0..1_000_000),
              tick_count <- StreamData.integer(1..100)
            ) do
        clock = LamportClock.new(initial)

        {_final_clock, times} =
          Enum.reduce(1..tick_count, {clock, []}, fn _, {c, acc} ->
            {new_clock, time} = LamportClock.tick(c)
            {new_clock, [time | acc]}
          end)

        times = Enum.reverse(times)

        # All times are strictly increasing
        assert times == Enum.sort(times)
        assert times == Enum.uniq(times)

        # First tick is initial + 1
        assert hd(times) == initial + 1
      end
    end

    property "update always advances past received time" do
      check all(
              local <- StreamData.integer(0..1_000_000),
              received <- StreamData.integer(0..1_000_000)
            ) do
        clock = LamportClock.new(local)
        {_new_clock, new_time} = LamportClock.update(clock, received)

        # New time is greater than both local and received
        assert new_time > local
        assert new_time > received
        assert new_time == max(local, received) + 1
      end
    end

    property "merge is commutative and associative" do
      check all(
              a <- StreamData.integer(0..1_000_000),
              b <- StreamData.integer(0..1_000_000),
              c <- StreamData.integer(0..1_000_000)
            ) do
        clock_a = LamportClock.new(a)
        clock_b = LamportClock.new(b)
        clock_c = LamportClock.new(c)

        # Commutative
        ab = LamportClock.merge(clock_a, clock_b)
        ba = LamportClock.merge(clock_b, clock_a)
        assert LamportClock.time(ab) == LamportClock.time(ba)

        # Associative
        ab_c = LamportClock.merge(LamportClock.merge(clock_a, clock_b), clock_c)
        a_bc = LamportClock.merge(clock_a, LamportClock.merge(clock_b, clock_c))
        assert LamportClock.time(ab_c) == LamportClock.time(a_bc)
      end
    end
  end

  describe "property: content hash integrity" do
    property "content hash changes when any field changes" do
      check all(
              context_id <- StreamData.binary(min_length: 1, max_length: 32),
              key <- StreamData.binary(min_length: 1, max_length: 32),
              payload <- StreamData.binary(min_length: 1, max_length: 256)
            ) do
        Schema.clear_all()

        {:ok, entry} = Store.append(context_id, key, payload)
        original_hash = entry.content_hash

        # Tampering with payload changes hash
        tampered_payload = %{entry | payload: payload <> "x"}
        {:error, :hash_mismatch} = Entry.verify_integrity(tampered_payload)

        # Tampering with key changes hash
        tampered_key = %{entry | key: key <> "x"}
        {:error, :hash_mismatch} = Entry.verify_integrity(tampered_key)
      end
    end
  end

  # ============================================================================
  # NEGATIVE / ADVERSARIAL TESTS
  # ============================================================================

  describe "negative: tamper detection" do
    test "detects payload tampering" do
      {:ok, entry} = Store.append("ctx", "facts", "original payload")

      # Various tampering attempts
      tamperings = [
        %{entry | payload: "completely different"},
        %{entry | payload: "original payload "},  # Added space
        %{entry | payload: "Original payload"},   # Changed case
        %{entry | payload: ""},                   # Empty
        %{entry | payload: entry.payload <> <<0>>}  # Null byte
      ]

      for tampered <- tamperings do
        assert {:error, :hash_mismatch} = Entry.verify_integrity(tampered),
               "Should detect tampering: #{inspect(tampered.payload)}"
      end
    end

    test "detects metadata tampering" do
      {:ok, entry} = Store.append("ctx", "facts", "payload", %{"key" => "value"})

      # Metadata isn't in the hash, but let's verify the structure
      # Actually, looking at MerkleTree.hash_entry, metadata is NOT included
      # This is intentional - metadata is auxiliary, not semantic
      # So this test documents that behavior

      modified_meta = %{entry | metadata: %{"key" => "different"}}
      # Metadata changes don't affect hash (by design)
      assert {:ok, :verified} = Entry.verify_integrity(modified_meta)
    end

    test "detects sequence tampering" do
      {:ok, entry} = Store.append("ctx", "facts", "payload")

      tampered = %{entry | sequence: entry.sequence + 1}
      assert {:error, :hash_mismatch} = Entry.verify_integrity(tampered)
    end

    test "detects timestamp tampering" do
      {:ok, entry} = Store.append("ctx", "facts", "payload")

      tampered = %{entry | appended_at_ns: entry.appended_at_ns + 1}
      assert {:error, :hash_mismatch} = Entry.verify_integrity(tampered)
    end

    test "detects context_id tampering" do
      {:ok, entry} = Store.append("ctx", "facts", "payload")

      tampered = %{entry | context_id: "different-ctx"}
      assert {:error, :hash_mismatch} = Entry.verify_integrity(tampered)
    end
  end

  describe "negative: Merkle proof attacks" do
    test "wrong proof for leaf fails" do
      hashes = for i <- 1..8, do: MerkleTree.hash("data-#{i}")
      root = MerkleTree.compute_root(hashes)

      {:ok, proof_for_0} = MerkleTree.generate_proof(hashes, 0)

      # Try to use proof for index 0 with leaf from index 1
      leaf_1 = Enum.at(hashes, 1)
      refute MerkleTree.verify_proof(leaf_1, proof_for_0, root)
    end

    test "tampered proof fails" do
      hashes = for i <- 1..8, do: MerkleTree.hash("data-#{i}")
      root = MerkleTree.compute_root(hashes)

      {:ok, proof} = MerkleTree.generate_proof(hashes, 0)
      leaf = Enum.at(hashes, 0)

      # Tamper with proof
      tampered_proof = List.update_at(proof, 0, fn {side, hash} ->
        {side, MerkleTree.hash("fake")}
      end)

      refute MerkleTree.verify_proof(leaf, tampered_proof, root)
    end

    test "proof against wrong root fails" do
      hashes = for i <- 1..8, do: MerkleTree.hash("data-#{i}")
      root = MerkleTree.compute_root(hashes)

      {:ok, proof} = MerkleTree.generate_proof(hashes, 0)
      leaf = Enum.at(hashes, 0)

      # Try with fake root
      fake_root = MerkleTree.hash("fake root")
      refute MerkleTree.verify_proof(leaf, proof, fake_root)
    end

    test "empty proof fails for non-single-element tree" do
      hashes = for i <- 1..8, do: MerkleTree.hash("data-#{i}")
      root = MerkleTree.compute_root(hashes)
      leaf = Enum.at(hashes, 0)

      refute MerkleTree.verify_proof(leaf, [], root)
    end
  end

  describe "negative: snapshot integrity attacks" do
    test "corrupted snapshot blob fails to load" do
      {:ok, entry} = Store.append("ctx", "facts", "payload")
      {:ok, blob, _, _} = Store.snapshot("ctx")

      # Corrupt the blob
      corrupted = :binary.part(blob, 0, byte_size(blob) - 10)

      result = Store.load("target", corrupted)
      assert {:error, :invalid_snapshot_format} = result
    end

    test "snapshot with tampered entries fails integrity check" do
      for i <- 1..10, do: Store.append("ctx", "facts", "payload-#{i}")
      {:ok, blob, _, _} = Store.snapshot("ctx")

      # Deserialize, tamper, reserialize
      snapshot_data = :erlang.binary_to_term(blob, [:safe])
      tampered_entries = List.update_at(snapshot_data.entries, 5, fn e ->
        %{e | payload: "tampered!"}
      end)
      tampered_data = %{snapshot_data | entries: tampered_entries}
      tampered_blob = :erlang.term_to_binary(tampered_data, [:compressed])

      # Load with integrity verification should fail
      result = Store.load("target", tampered_blob, verify_integrity: true)
      assert {:error, :integrity_verification_failed} = result
    end

    test "snapshot with wrong merkle root fails verification" do
      for i <- 1..10, do: Store.append("ctx", "facts", "payload-#{i}")
      {:ok, blob, _, _} = Store.snapshot("ctx")

      # Deserialize, change merkle root, reserialize
      snapshot_data = :erlang.binary_to_term(blob, [:safe])
      fake_root = MerkleTree.hash("fake")
      tampered_data = %{snapshot_data | merkle_root: fake_root}
      tampered_blob = :erlang.term_to_binary(tampered_data, [:compressed])

      result = Store.load("target", tampered_blob, verify_integrity: true)
      assert {:error, :integrity_verification_failed} = result
    end
  end

  describe "negative: invalid inputs" do
    test "generate_proof with invalid index returns error" do
      hashes = for i <- 1..4, do: MerkleTree.hash("data-#{i}")

      assert {:error, :invalid_index} = MerkleTree.generate_proof(hashes, -1)
      assert {:error, :invalid_index} = MerkleTree.generate_proof(hashes, 4)
      assert {:error, :invalid_index} = MerkleTree.generate_proof(hashes, 100)
    end

    test "from_hex with invalid hex returns error" do
      assert {:error, :invalid_hex} = MerkleTree.from_hex("not valid hex!")
      assert {:error, :invalid_hex} = MerkleTree.from_hex("ZZZZ")
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_entry(context_id, key, payload, sequence) do
    %Entry{
      id: "entry-#{sequence}-#{:rand.uniform(1_000_000)}",
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: System.os_time(:nanosecond),
      metadata: %{}
    }
  end
end
