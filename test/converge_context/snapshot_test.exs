defmodule ConvergeContext.SnapshotTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ConvergeContext.Storage.Schema
  alias ConvergeContext.Storage.Store

  setup do
    :mnesia.start()
    Schema.init()

    # Wait for tables to be ready
    :mnesia.wait_for_tables([Schema.entries_table(), Schema.sequences_table()], 5000)

    Schema.clear_all()
    :ok
  end

  # Generators - use random bytes to ensure unique context IDs per check
  defp context_id_gen do
    StreamData.map(
      StreamData.binary(length: 8),
      fn bytes -> Base.encode16(bytes, case: :lower) end
    )
  end

  defp key_gen do
    StreamData.member_of(["facts", "intents", "traces", "evaluations"])
  end

  defp payload_gen do
    StreamData.binary(min_length: 1, max_length: 256)
  end

  defp metadata_gen do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
      StreamData.string(:printable, max_length: 32),
      max_length: 3
    )
  end

  defp append_operation_gen do
    StreamData.tuple({key_gen(), payload_gen(), metadata_gen()})
  end

  # Unit Tests

  describe "snapshot/1 unit tests" do
    test "empty context produces valid snapshot" do
      {:ok, blob, seq, meta} = Store.snapshot("empty-ctx")

      assert is_binary(blob)
      assert seq == 0
      assert meta.entry_count == 0
      assert meta.version == 1
      assert meta.created_at_ns > 0
    end

    test "snapshot metadata has correct entry count" do
      for i <- 1..15, do: Store.append("ctx", "facts", "payload-#{i}")

      {:ok, _, _, meta} = Store.snapshot("ctx")
      assert meta.entry_count == 15
    end

    test "snapshot includes all entry types" do
      Store.append("ctx", "facts", "p1")
      Store.append("ctx", "intents", "p2")
      Store.append("ctx", "traces", "p3")

      {:ok, blob, _, _} = Store.snapshot("ctx")
      {:ok, count, _} = Store.load("new-ctx", blob)

      assert count == 3
    end

    test "multiple snapshots of same context are consistent" do
      for i <- 1..10, do: Store.append("ctx", "facts", "payload-#{i}")

      {:ok, blob1, seq1, meta1} = Store.snapshot("ctx")
      {:ok, blob2, seq2, meta2} = Store.snapshot("ctx")

      assert seq1 == seq2
      assert meta1.entry_count == meta2.entry_count
      # Blobs may differ in timestamp but content should be same
      assert byte_size(blob1) == byte_size(blob2)
    end
  end

  describe "load/3 unit tests" do
    test "load into empty context succeeds" do
      Store.append("source", "facts", "payload")
      {:ok, blob, _, _} = Store.snapshot("source")

      {:ok, count, seq} = Store.load("target", blob)

      assert count == 1
      assert seq == 1
    end

    test "load into existing context appends entries" do
      # Create source with 5 entries
      for i <- 1..5, do: Store.append("source", "facts", "src-#{i}")
      {:ok, blob, _, _} = Store.snapshot("source")

      # Create target with 3 entries
      for i <- 1..3, do: Store.append("target", "facts", "tgt-#{i}")

      # Load - should add entries (not replace)
      {:ok, count, seq} = Store.load("target", blob)

      assert count == 5
      # Sequence should be max of target's original (3) and source's (5)
      assert seq == 5

      {:ok, entries, _} = Store.get("target")
      # Has both target's original and loaded entries
      assert length(entries) == 8
    end

    test "fail_if_exists prevents loading into non-empty context" do
      Store.append("source", "facts", "payload")
      {:ok, blob, _, _} = Store.snapshot("source")

      Store.append("target", "facts", "existing")

      {:error, :context_already_exists} = Store.load("target", blob, true)

      # Original entry still there
      {:ok, entries, _} = Store.get("target")
      assert length(entries) == 1
      assert hd(entries).payload == "existing"
    end

    test "fail_if_exists allows loading into empty context" do
      Store.append("source", "facts", "payload")
      {:ok, blob, _, _} = Store.snapshot("source")

      {:ok, count, _} = Store.load("new-target", blob, true)
      assert count == 1
    end

    test "invalid snapshot format returns error" do
      {:error, :invalid_snapshot_format} = Store.load("ctx", "not valid")
      {:error, :invalid_snapshot_format} = Store.load("ctx", <<0, 1, 2, 3>>)
      {:error, :invalid_snapshot_format} = Store.load("ctx", "")
    end

    test "corrupted snapshot returns error" do
      Store.append("source", "facts", "payload")
      {:ok, blob, _, _} = Store.snapshot("source")

      # Corrupt the blob by changing bytes
      corrupted = :binary.replace(blob, <<131>>, <<132>>, [:global])

      result = Store.load("target", corrupted)
      assert match?({:error, _}, result)
    end

    test "loading preserves entry metadata" do
      Store.append("source", "facts", "payload", %{"agent" => "test", "cycle" => "5"})
      {:ok, blob, _, _} = Store.snapshot("source")

      {:ok, _, _} = Store.load("target", blob)

      {:ok, [entry], _} = Store.get("target")
      assert entry.metadata == %{"agent" => "test", "cycle" => "5"}
    end
  end

  # Property Tests

  describe "property: snapshot/load round-trip" do
    property "all entries are preserved through snapshot/load" do
      check all(
              source_ctx <- context_id_gen(),
              target_ctx <- context_id_gen(),
              operations <- StreamData.list_of(append_operation_gen(), min_length: 1, max_length: 20)
            ) do
        # Append entries to source (unique context per check, no clear needed)
        appended_entries =
          for {key, payload, metadata} <- operations do
            {:ok, entry} = Store.append(source_ctx, key, payload, metadata)
            entry
          end

        # Snapshot and load
        {:ok, blob, _, _} = Store.snapshot(source_ctx)
        {:ok, count, _} = Store.load(target_ctx, blob)

        assert count == length(operations)

        # Compare entries
        {:ok, source_entries, _} = Store.get(source_ctx)
        {:ok, target_entries, _} = Store.get(target_ctx)

        # Verify appended entries match what we get back
        assert length(source_entries) == length(appended_entries)
        assert length(target_entries) == length(appended_entries)

        # All payloads match
        source_payloads = Enum.map(source_entries, & &1.payload) |> Enum.sort()
        target_payloads = Enum.map(target_entries, & &1.payload) |> Enum.sort()
        expected_payloads = Enum.map(appended_entries, & &1.payload) |> Enum.sort()

        assert source_payloads == expected_payloads
        assert target_payloads == expected_payloads
      end
    end

    property "snapshot metadata is accurate" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(1..50)
            ) do
        # Append entries
        for _ <- 1..count, do: Store.append(context_id, "facts", "payload")

        {:ok, _, seq, meta} = Store.snapshot(context_id)

        assert meta.entry_count == count
        assert seq == count
        assert meta.version == 1
        assert meta.created_at_ns > 0
      end
    end

    property "loaded entries maintain sequence order" do
      check all(
              source_ctx <- context_id_gen(),
              target_ctx <- context_id_gen(),
              count <- StreamData.integer(1..30)
            ) do
        target_ctx = if source_ctx == target_ctx, do: target_ctx <> "-t", else: target_ctx

        Schema.clear_all()

        for i <- 1..count, do: Store.append(source_ctx, "facts", "payload-#{i}")

        {:ok, blob, _, _} = Store.snapshot(source_ctx)
        {:ok, _, _} = Store.load(target_ctx, blob)

        {:ok, entries, _} = Store.get(target_ctx)
        sequences = Enum.map(entries, & &1.sequence)

        assert sequences == Enum.sort(sequences)
      end
    end

    property "double snapshot/load is consistent" do
      check all(
              ctx1 <- context_id_gen(),
              ctx2 <- context_id_gen(),
              ctx3 <- context_id_gen(),
              operations <- StreamData.list_of(append_operation_gen(), min_length: 1, max_length: 15)
            ) do
        # Append to ctx1 (unique per check)
        appended =
          for {key, payload, metadata} <- operations do
            {:ok, entry} = Store.append(ctx1, key, payload, metadata)
            entry
          end

        # First round-trip
        {:ok, blob1, _, _} = Store.snapshot(ctx1)
        {:ok, count1, _} = Store.load(ctx2, blob1)

        # Second round-trip
        {:ok, blob2, _, _} = Store.snapshot(ctx2)
        {:ok, count2, _} = Store.load(ctx3, blob2)

        # Counts should match
        assert count1 == length(appended)
        assert count2 == length(appended)

        # All contexts should have same entries
        {:ok, entries1, _} = Store.get(ctx1)
        {:ok, entries2, _} = Store.get(ctx2)
        {:ok, entries3, _} = Store.get(ctx3)

        assert length(entries1) == length(appended)
        assert length(entries2) == length(appended)
        assert length(entries3) == length(appended)

        # Payloads should be identical
        payloads1 = Enum.map(entries1, & &1.payload) |> Enum.sort()
        payloads2 = Enum.map(entries2, & &1.payload) |> Enum.sort()
        payloads3 = Enum.map(entries3, & &1.payload) |> Enum.sort()

        assert payloads1 == payloads2
        assert payloads2 == payloads3
      end
    end
  end

  describe "property: snapshot blob properties" do
    property "snapshot blob is deterministic for entry content" do
      check all(
              context_id <- context_id_gen(),
              key <- key_gen(),
              payload <- payload_gen()
            ) do
        Schema.clear_all()
        Store.append(context_id, key, payload)

        {:ok, blob1, seq1, _} = Store.snapshot(context_id)
        {:ok, blob2, seq2, _} = Store.snapshot(context_id)

        # Sequence should be same
        assert seq1 == seq2

        # Blob sizes should be same (timestamps may differ slightly)
        assert byte_size(blob1) == byte_size(blob2)
      end
    end

    property "larger contexts produce larger snapshots" do
      check all(
              context_id <- context_id_gen(),
              count1 <- StreamData.integer(1..10),
              count2 <- StreamData.integer(20..30)
            ) do
        Schema.clear_all()

        # Small context
        for _ <- 1..count1, do: Store.append(context_id <> "-small", "facts", "payload")
        {:ok, small_blob, _, _} = Store.snapshot(context_id <> "-small")

        # Large context
        for _ <- 1..count2, do: Store.append(context_id <> "-large", "facts", "payload")
        {:ok, large_blob, _, _} = Store.snapshot(context_id <> "-large")

        assert byte_size(large_blob) > byte_size(small_blob)
      end
    end
  end

  describe "property: load sequence handling" do
    property "loaded sequence is at least source sequence" do
      check all(
              source_ctx <- context_id_gen(),
              target_ctx <- context_id_gen(),
              source_count <- StreamData.integer(1..20)
            ) do
        # Use unique target context (no pre-existing entries)
        for _ <- 1..source_count, do: Store.append(source_ctx, "facts", "src")

        {:ok, blob, source_seq, _} = Store.snapshot(source_ctx)
        {:ok, _, loaded_seq} = Store.load(target_ctx, blob)

        # Loaded sequence should be at least the source sequence
        assert loaded_seq >= source_seq
        assert loaded_seq == source_seq
      end
    end
  end

  describe "property: empty context handling" do
    property "empty context snapshots load correctly" do
      check all(target_ctx <- context_id_gen()) do
        Schema.clear_all()

        {:ok, blob, 0, meta} = Store.snapshot("empty-source")
        assert meta.entry_count == 0

        {:ok, count, seq} = Store.load(target_ctx, blob)

        assert count == 0
        assert seq == 0

        {:ok, entries, _} = Store.get(target_ctx)
        assert entries == []
      end
    end
  end

  describe "property: metadata preservation" do
    property "all metadata is preserved through snapshot/load" do
      check all(
              source_ctx <- context_id_gen(),
              target_ctx <- context_id_gen(),
              key <- key_gen(),
              payload <- payload_gen(),
              metadata <- metadata_gen()
            ) do
        # Ensure unique contexts
        target_ctx = if source_ctx == target_ctx, do: target_ctx <> "-tgt", else: target_ctx

        # Debug: Check table state before append
        table = Schema.entries_table()

        # Debug: Check index configuration
        index_config = :mnesia.table_info(table, :index)
        attributes = :mnesia.table_info(table, :attributes)

        {:atomic, pre_count} =
          :mnesia.transaction(fn ->
            :mnesia.foldr(fn _, acc -> acc + 1 end, 0, table)
          end)

        # Append to source (unique context per check)
        {:ok, appended} = Store.append(source_ctx, key, payload, metadata)

        # Debug: Check table state after append
        {:atomic, post_count} =
          :mnesia.transaction(fn ->
            :mnesia.foldr(fn _, acc -> acc + 1 end, 0, table)
          end)

        # Debug: Check raw index read - try both by atom and position
        {:atomic, raw_read_atom} =
          :mnesia.transaction(fn ->
            :mnesia.index_read(table, source_ctx, :context_id)
          end)

        {:atomic, raw_read_pos} =
          :mnesia.transaction(fn ->
            :mnesia.index_read(table, source_ctx, 3)
          end)

        # Debug: Check all entries and their context_ids
        {:atomic, all_entries} =
          :mnesia.transaction(fn ->
            :mnesia.foldr(fn rec, acc -> [rec | acc] end, [], table)
          end)

        matching_entries = Enum.filter(all_entries, fn rec ->
          elem(rec, 2) == source_ctx
        end)

        IO.puts(
          "DEBUG: pre=#{pre_count}, post=#{post_count}, by_atom=#{length(raw_read_atom)}, by_pos=#{length(raw_read_pos)}, manual_filter=#{length(matching_entries)}, source_ctx=#{source_ctx}, index=#{inspect(index_config)}, attrs=#{inspect(attributes)}"
        )

        # Verify append worked
        assert appended.metadata == metadata
        assert appended.payload == payload

        # Snapshot and load
        {:ok, blob, _, _} = Store.snapshot(source_ctx)
        {:ok, count, _} = Store.load(target_ctx, blob)

        assert count == 1

        # Get entries
        {:ok, source_entries, _} = Store.get(source_ctx)
        {:ok, target_entries, _} = Store.get(target_ctx)

        # Should have exactly one entry each (unique context)
        assert length(source_entries) == 1
        assert length(target_entries) == 1

        [source_entry] = source_entries
        [target_entry] = target_entries

        assert source_entry.metadata == metadata
        assert target_entry.metadata == metadata
        assert source_entry.payload == payload
        assert target_entry.payload == payload
      end
    end
  end
end
