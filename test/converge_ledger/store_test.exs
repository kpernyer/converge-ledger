defmodule ConvergeLedger.StoreTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ConvergeLedger.Storage.Schema
  alias ConvergeLedger.Storage.Store

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
    StreamData.member_of(["facts", "intents", "traces", "evaluations", "hypotheses", "signals"])
  end

  defp payload_gen do
    StreamData.binary(min_length: 1, max_length: 512)
  end

  defp metadata_gen do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
      StreamData.string(:printable, max_length: 64),
      max_length: 5
    )
  end

  defp append_operation_gen do
    StreamData.tuple({key_gen(), payload_gen(), metadata_gen()})
  end

  # Unit Tests - Edge Cases

  describe "append/4 edge cases" do
    test "handles very long context_id" do
      long_id = String.duplicate("a", 1000)
      {:ok, entry} = Store.append(long_id, "facts", "payload")
      assert entry.context_id == long_id
    end

    test "handles very long key" do
      long_key = String.duplicate("k", 500)
      {:ok, entry} = Store.append("ctx", long_key, "payload")
      assert entry.key == long_key
    end

    test "handles large payload" do
      large_payload = :crypto.strong_rand_bytes(100_000)
      {:ok, entry} = Store.append("ctx", "facts", large_payload)
      assert entry.payload == large_payload
    end

    test "handles empty metadata map" do
      {:ok, entry} = Store.append("ctx", "facts", "payload", %{})
      assert entry.metadata == %{}
    end

    test "handles metadata with special characters in values" do
      metadata = %{"key" => "value with\nnewlines\tand\ttabs"}
      {:ok, entry} = Store.append("ctx", "facts", "payload", metadata)
      assert entry.metadata == metadata
    end

    test "handles concurrent appends to same context" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Store.append("concurrent-ctx", "facts", "payload-#{i}")
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      {:ok, entries, seq} = Store.get("concurrent-ctx")
      assert length(entries) == 100
      assert seq == 100

      # All sequences should be unique
      sequences = Enum.map(entries, & &1.sequence)
      assert length(sequences) == length(Enum.uniq(sequences))
    end

    test "handles concurrent appends to different contexts" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Store.append("ctx-#{i}", "facts", "payload")
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Each context should have sequence 1
      for i <- 1..50 do
        {:ok, seq} = Store.current_sequence("ctx-#{i}")
        assert seq == 1
      end
    end
  end

  describe "get/2 edge cases" do
    test "filters work together" do
      for i <- 1..10 do
        key = if rem(i, 2) == 0, do: "even", else: "odd"
        Store.append("ctx", key, "payload-#{i}")
      end

      # Filter by key and after_sequence
      {:ok, entries, _} = Store.get("ctx", key: "even", after_sequence: 4)

      assert length(entries) == 3
      assert Enum.all?(entries, &(&1.key == "even"))
      assert Enum.all?(entries, &(&1.sequence > 4))
    end

    test "limit with after_sequence" do
      for i <- 1..20, do: Store.append("ctx", "facts", "payload-#{i}")

      {:ok, entries, _} = Store.get("ctx", after_sequence: 10, limit: 5)

      assert length(entries) == 5
      assert Enum.map(entries, & &1.sequence) == [11, 12, 13, 14, 15]
    end

    test "returns entries in sequence order" do
      # Append in random order simulation
      for _ <- 1..50 do
        Store.append("ctx", "facts", :crypto.strong_rand_bytes(32))
      end

      {:ok, entries, _} = Store.get("ctx")
      sequences = Enum.map(entries, & &1.sequence)

      assert sequences == Enum.sort(sequences)
    end

    test "handles limit larger than entry count" do
      for i <- 1..5, do: Store.append("ctx", "facts", "p#{i}")

      {:ok, entries, _} = Store.get("ctx", limit: 100)
      assert length(entries) == 5
    end

    test "handles after_sequence larger than current sequence" do
      for i <- 1..5, do: Store.append("ctx", "facts", "p#{i}")

      {:ok, entries, seq} = Store.get("ctx", after_sequence: 100)
      assert entries == []
      assert seq == 5
    end
  end

  describe "current_sequence/1 edge cases" do
    test "is consistent with appended entries" do
      for i <- 1..10 do
        {:ok, entry} = Store.append("ctx", "facts", "p#{i}")
        {:ok, seq} = Store.current_sequence("ctx")
        assert seq == entry.sequence
        assert seq == i
      end
    end

    test "works for multiple contexts independently" do
      Store.append("ctx-a", "facts", "p1")
      Store.append("ctx-a", "facts", "p2")
      Store.append("ctx-b", "facts", "p1")

      {:ok, seq_a} = Store.current_sequence("ctx-a")
      {:ok, seq_b} = Store.current_sequence("ctx-b")

      assert seq_a == 2
      assert seq_b == 1
    end
  end

  # Property Tests

  describe "property: append/get round-trip" do
    property "all appended entries can be retrieved" do
      check all(
              context_id <- context_id_gen(),
              operations <-
                StreamData.list_of(append_operation_gen(), min_length: 1, max_length: 20)
            ) do
        Schema.clear_all()

        # Append all operations
        appended =
          Enum.map(operations, fn {key, payload, metadata} ->
            {:ok, entry} = Store.append(context_id, key, payload, metadata)
            entry
          end)

        # Retrieve all
        {:ok, retrieved, _} = Store.get(context_id)

        # Same count
        assert length(retrieved) == length(appended)

        # All entries present (by ID)
        appended_ids = MapSet.new(Enum.map(appended, & &1.id))
        retrieved_ids = MapSet.new(Enum.map(retrieved, & &1.id))
        assert MapSet.equal?(appended_ids, retrieved_ids)
      end
    end

    property "payloads are preserved exactly" do
      check all(
              context_id <- context_id_gen(),
              payloads <- StreamData.list_of(payload_gen(), min_length: 1, max_length: 10)
            ) do
        Schema.clear_all()

        for payload <- payloads do
          Store.append(context_id, "facts", payload)
        end

        {:ok, entries, _} = Store.get(context_id)
        retrieved_payloads = Enum.map(entries, & &1.payload)

        assert retrieved_payloads == payloads
      end
    end

    property "metadata is preserved exactly" do
      check all(
              context_id <- context_id_gen(),
              key <- key_gen(),
              payload <- payload_gen(),
              metadata <- metadata_gen()
            ) do
        Schema.clear_all()

        {:ok, entry} = Store.append(context_id, key, payload, metadata)
        {:ok, [retrieved], _} = Store.get(context_id)

        assert retrieved.metadata == metadata
        assert retrieved.metadata == entry.metadata
      end
    end
  end

  describe "property: sequence numbers" do
    property "sequences are strictly monotonically increasing" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(1..50)
            ) do
        Schema.clear_all()

        entries =
          for _ <- 1..count do
            {:ok, entry} = Store.append(context_id, "facts", "payload")
            entry
          end

        sequences = Enum.map(entries, & &1.sequence)

        # Strictly increasing
        sequences
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] ->
          assert b == a + 1
        end)

        # Starts at 1
        assert hd(sequences) == 1

        # Ends at count
        assert List.last(sequences) == count
      end
    end

    property "current_sequence matches last appended sequence" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(1..30)
            ) do
        Schema.clear_all()

        last_entry =
          for _ <- 1..count, reduce: nil do
            _ ->
              {:ok, entry} = Store.append(context_id, "facts", "payload")
              entry
          end

        {:ok, seq} = Store.current_sequence(context_id)
        assert seq == last_entry.sequence
        assert seq == count
      end
    end

    property "sequences are independent per context" do
      check all(
              contexts <-
                StreamData.list_of(context_id_gen(), min_length: 2, max_length: 5)
                |> StreamData.map(&Enum.uniq/1)
                |> StreamData.filter(&(length(&1) >= 2)),
              counts <-
                StreamData.list_of(StreamData.integer(1..10), min_length: 2, max_length: 5)
            ) do
        Schema.clear_all()

        # Zip contexts with counts, taking min length
        pairs = Enum.zip(contexts, counts)

        # Append to each context
        for {ctx, count} <- pairs do
          for _ <- 1..count, do: Store.append(ctx, "facts", "payload")
        end

        # Verify each context has correct sequence
        for {ctx, count} <- pairs do
          {:ok, seq} = Store.current_sequence(ctx)
          assert seq == count
        end
      end
    end
  end

  describe "property: key filtering" do
    property "key filter returns only matching entries" do
      check all(
              context_id <- context_id_gen(),
              operations <-
                StreamData.list_of(append_operation_gen(), min_length: 1, max_length: 30)
            ) do
        Schema.clear_all()

        for {key, payload, metadata} <- operations do
          Store.append(context_id, key, payload, metadata)
        end

        # Get unique keys that were used
        used_keys = operations |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        for key <- used_keys do
          {:ok, entries, _} = Store.get(context_id, key: key)

          # All entries have the requested key
          assert Enum.all?(entries, &(&1.key == key))

          # Count matches expected
          expected_count = Enum.count(operations, &(elem(&1, 0) == key))
          assert length(entries) == expected_count
        end
      end
    end
  end

  describe "property: after_sequence filtering" do
    property "after_sequence returns only entries with higher sequence" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(5..30),
              after_seq <- StreamData.integer(0..30)
            ) do
        Schema.clear_all()

        for _ <- 1..count, do: Store.append(context_id, "facts", "payload")

        {:ok, entries, latest} = Store.get(context_id, after_sequence: after_seq)

        # All returned entries have sequence > after_seq
        assert Enum.all?(entries, &(&1.sequence > after_seq))

        # Count is correct
        expected_count = max(0, count - after_seq)
        assert length(entries) == expected_count

        # Latest sequence is always the total count
        assert latest == count
      end
    end
  end

  describe "property: limit" do
    property "limit caps the number of returned entries" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(1..50),
              limit <- StreamData.integer(1..50)
            ) do
        Schema.clear_all()

        for _ <- 1..count, do: Store.append(context_id, "facts", "payload")

        {:ok, entries, _} = Store.get(context_id, limit: limit)

        assert length(entries) <= limit
        assert length(entries) == min(count, limit)
      end
    end

    property "limited results are in sequence order starting from 1" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(5..30),
              limit <- StreamData.integer(1..10)
            ) do
        Schema.clear_all()

        for _ <- 1..count, do: Store.append(context_id, "facts", "payload")

        {:ok, entries, _} = Store.get(context_id, limit: limit)

        sequences = Enum.map(entries, & &1.sequence)
        assert sequences == Enum.to_list(1..min(count, limit))
      end
    end
  end

  describe "property: entry ordering" do
    property "entries are always returned in sequence order" do
      check all(
              context_id <- context_id_gen(),
              operations <-
                StreamData.list_of(append_operation_gen(), min_length: 1, max_length: 50)
            ) do
        Schema.clear_all()

        for {key, payload, metadata} <- operations do
          Store.append(context_id, key, payload, metadata)
        end

        {:ok, entries, _} = Store.get(context_id)
        sequences = Enum.map(entries, & &1.sequence)

        # Sorted ascending
        assert sequences == Enum.sort(sequences)

        # Consecutive starting from 1
        assert sequences == Enum.to_list(1..length(operations))
      end
    end
  end

  describe "property: context isolation" do
    property "operations on one context don't affect another" do
      check all(
              ctx_a <- context_id_gen(),
              ctx_b <- context_id_gen(),
              count_a <- StreamData.integer(1..20),
              count_b <- StreamData.integer(1..20)
            ) do
        # Ensure different contexts
        ctx_b = if ctx_a == ctx_b, do: ctx_b <> "-different", else: ctx_b

        Schema.clear_all()

        # Append to both contexts
        for _ <- 1..count_a, do: Store.append(ctx_a, "facts", "payload-a")
        for _ <- 1..count_b, do: Store.append(ctx_b, "facts", "payload-b")

        # Verify isolation
        {:ok, entries_a, seq_a} = Store.get(ctx_a)
        {:ok, entries_b, seq_b} = Store.get(ctx_b)

        assert length(entries_a) == count_a
        assert length(entries_b) == count_b
        assert seq_a == count_a
        assert seq_b == count_b

        # Payloads are correct for each context
        assert Enum.all?(entries_a, &(&1.payload == "payload-a"))
        assert Enum.all?(entries_b, &(&1.payload == "payload-b"))
      end
    end
  end
end
