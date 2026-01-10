defmodule ConvergeLedger.EntryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ConvergeLedger.Entry

  # Generators for property tests
  defp context_id_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 64)
  end

  defp key_gen do
    StreamData.member_of(["facts", "intents", "traces", "evaluations", "hypotheses"])
  end

  defp payload_gen do
    StreamData.binary(min_length: 0, max_length: 1024)
  end

  defp sequence_gen do
    StreamData.positive_integer()
  end

  defp metadata_key_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 32)
  end

  defp metadata_gen do
    StreamData.map_of(metadata_key_gen(), StreamData.string(:printable), max_length: 10)
  end

  # Unit Tests

  describe "Entry.new/5" do
    test "creates entry with all required fields" do
      entry = Entry.new("ctx-1", "facts", "test-payload", 1)

      assert entry.context_id == "ctx-1"
      assert entry.key == "facts"
      assert entry.payload == "test-payload"
      assert entry.sequence == 1
      assert entry.metadata == %{}
    end

    test "generates unique 32-character hex ID" do
      entry1 = Entry.new("ctx", "key", "payload", 1)
      entry2 = Entry.new("ctx", "key", "payload", 2)

      assert String.length(entry1.id) == 32
      assert String.length(entry2.id) == 32
      assert entry1.id != entry2.id
      assert Regex.match?(~r/^[0-9a-f]{32}$/, entry1.id)
    end

    test "sets timestamp to current time in nanoseconds" do
      before = System.os_time(:nanosecond)
      entry = Entry.new("ctx", "key", "payload", 1)
      after_time = System.os_time(:nanosecond)

      assert entry.appended_at_ns >= before
      assert entry.appended_at_ns <= after_time
    end

    test "accepts metadata map" do
      metadata = %{"agent_id" => "test-agent", "cycle" => "5"}
      entry = Entry.new("ctx", "key", "payload", 1, metadata)

      assert entry.metadata == metadata
    end

    test "handles empty payload" do
      entry = Entry.new("ctx", "key", "", 1)
      assert entry.payload == ""
    end

    test "handles binary payload with special characters" do
      payload = <<0, 1, 2, 255, 128, 64>>
      entry = Entry.new("ctx", "key", payload, 1)
      assert entry.payload == payload
    end

    test "handles unicode in context_id and key" do
      entry = Entry.new("context-日本語", "key-émoji-🎉", "payload", 1)
      assert entry.context_id == "context-日本語"
      assert entry.key == "key-émoji-🎉"
    end
  end

  describe "Entry.to_record/1 and Entry.from_record/1" do
    test "round-trips preserve all fields" do
      entry = Entry.new("ctx", "key", "payload", 42, %{"foo" => "bar"})
      record = Entry.to_record(entry)
      restored = Entry.from_record(record)

      assert restored.id == entry.id
      assert restored.context_id == entry.context_id
      assert restored.key == entry.key
      assert restored.payload == entry.payload
      assert restored.sequence == entry.sequence
      assert restored.appended_at_ns == entry.appended_at_ns
      assert restored.metadata == entry.metadata
    end

    test "record tuple has correct structure" do
      entry = Entry.new("ctx", "key", "payload", 1, %{"meta" => "data"})
      record = Entry.to_record(entry)

      assert is_tuple(record)
      assert tuple_size(record) == 8
      assert elem(record, 0) == :context_entries
      assert elem(record, 1) == entry.id
      assert elem(record, 2) == entry.context_id
    end

    test "handles empty metadata" do
      entry = Entry.new("ctx", "key", "payload", 1)
      record = Entry.to_record(entry)
      restored = Entry.from_record(record)

      assert restored.metadata == %{}
    end

    test "handles large metadata" do
      metadata = for i <- 1..100, into: %{}, do: {"key_#{i}", "value_#{i}"}
      entry = Entry.new("ctx", "key", "payload", 1, metadata)
      record = Entry.to_record(entry)
      restored = Entry.from_record(record)

      assert restored.metadata == metadata
    end
  end

  # Property Tests

  describe "property: Entry creation" do
    property "always generates valid entries" do
      check all(
              context_id <- context_id_gen(),
              key <- key_gen(),
              payload <- payload_gen(),
              sequence <- sequence_gen(),
              metadata <- metadata_gen()
            ) do
        entry = Entry.new(context_id, key, payload, sequence, metadata)

        # ID is always 32-char hex
        assert String.length(entry.id) == 32
        assert Regex.match?(~r/^[0-9a-f]{32}$/, entry.id)

        # All fields preserved
        assert entry.context_id == context_id
        assert entry.key == key
        assert entry.payload == payload
        assert entry.sequence == sequence
        assert entry.metadata == metadata

        # Timestamp is positive
        assert entry.appended_at_ns > 0
      end
    end

    property "IDs are unique across entries" do
      check all(
              entries <-
                StreamData.list_of(
                  StreamData.tuple(
                    {context_id_gen(), key_gen(), payload_gen(), sequence_gen()}
                  ),
                  min_length: 2,
                  max_length: 100
                )
            ) do
        created =
          Enum.map(entries, fn {ctx, key, payload, seq} ->
            Entry.new(ctx, key, payload, seq)
          end)

        ids = Enum.map(created, & &1.id)
        assert length(ids) == length(Enum.uniq(ids))
      end
    end

    property "timestamps are monotonically increasing within tight loops" do
      check all(count <- StreamData.integer(2..50)) do
        entries =
          for seq <- 1..count do
            Entry.new("ctx", "key", "payload", seq)
          end

        timestamps = Enum.map(entries, & &1.appended_at_ns)

        # Each timestamp should be >= previous (monotonic)
        timestamps
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [t1, t2] ->
          assert t2 >= t1
        end)
      end
    end
  end

  describe "property: Record round-trip" do
    property "to_record/from_record is identity" do
      check all(
              context_id <- context_id_gen(),
              key <- key_gen(),
              payload <- payload_gen(),
              sequence <- sequence_gen(),
              metadata <- metadata_gen()
            ) do
        original = Entry.new(context_id, key, payload, sequence, metadata)
        restored = original |> Entry.to_record() |> Entry.from_record()

        assert restored.id == original.id
        assert restored.context_id == original.context_id
        assert restored.key == original.key
        assert restored.payload == original.payload
        assert restored.sequence == original.sequence
        assert restored.appended_at_ns == original.appended_at_ns
        assert restored.metadata == original.metadata
      end
    end

    property "double round-trip is idempotent" do
      check all(
              context_id <- context_id_gen(),
              key <- key_gen(),
              payload <- payload_gen(),
              sequence <- sequence_gen()
            ) do
        original = Entry.new(context_id, key, payload, sequence)

        once = original |> Entry.to_record() |> Entry.from_record()
        twice = once |> Entry.to_record() |> Entry.from_record()

        assert once.id == twice.id
        assert once.context_id == twice.context_id
        assert once.key == twice.key
        assert once.payload == twice.payload
        assert once.sequence == twice.sequence
        assert once.appended_at_ns == twice.appended_at_ns
      end
    end
  end

  describe "property: Entry struct invariants" do
    property "sequence is always positive" do
      check all(sequence <- sequence_gen()) do
        entry = Entry.new("ctx", "key", "payload", sequence)
        assert entry.sequence > 0
      end
    end

    property "payload binary integrity" do
      check all(payload <- StreamData.binary(min_length: 0, max_length: 10_000)) do
        entry = Entry.new("ctx", "key", payload, 1)
        assert entry.payload == payload
        assert byte_size(entry.payload) == byte_size(payload)
      end
    end

    property "metadata keys and values are preserved" do
      check all(metadata <- metadata_gen()) do
        entry = Entry.new("ctx", "key", "payload", 1, metadata)

        Enum.each(metadata, fn {k, v} ->
          assert Map.get(entry.metadata, k) == v
        end)

        assert map_size(entry.metadata) == map_size(metadata)
      end
    end
  end
end
