defmodule ConvergeContextTest do
  @moduledoc """
  Integration tests for ConvergeContext public API.

  Unit tests and property tests are in separate files under test/converge_context/.
  """

  use ExUnit.Case

  alias ConvergeContext.Storage.Schema

  setup do
    :mnesia.start()
    Schema.init()
    Schema.clear_all()
    :ok
  end

  describe "public API delegation" do
    test "append/4 delegates to Store" do
      {:ok, entry} = ConvergeContext.append("test-ctx", "facts", "payload")

      assert entry.context_id == "test-ctx"
      assert entry.key == "facts"
      assert entry.payload == "payload"
      assert entry.sequence == 1
    end

    test "get/2 delegates to Store" do
      {:ok, _} = ConvergeContext.append("test-ctx", "facts", "p1")
      {:ok, _} = ConvergeContext.append("test-ctx", "facts", "p2")

      {:ok, entries, seq} = ConvergeContext.get("test-ctx")

      assert length(entries) == 2
      assert seq == 2
    end

    test "snapshot/1 delegates to Store" do
      {:ok, _} = ConvergeContext.append("test-ctx", "facts", "payload")

      {:ok, blob, seq, meta} = ConvergeContext.snapshot("test-ctx")

      assert is_binary(blob)
      assert seq == 1
      assert meta.entry_count == 1
    end

    test "load/3 delegates to Store" do
      {:ok, _} = ConvergeContext.append("source", "facts", "payload")
      {:ok, blob, _, _} = ConvergeContext.snapshot("source")

      {:ok, count, seq} = ConvergeContext.load("target", blob)

      assert count == 1
      assert seq == 1
    end

    test "current_sequence/1 delegates to Store" do
      {:ok, _} = ConvergeContext.append("test-ctx", "facts", "p1")
      {:ok, _} = ConvergeContext.append("test-ctx", "facts", "p2")

      {:ok, seq} = ConvergeContext.current_sequence("test-ctx")

      assert seq == 2
    end
  end

  describe "end-to-end workflow" do
    test "complete append -> get -> snapshot -> load cycle" do
      # 1. Append entries to source context
      for i <- 1..10 do
        metadata = %{"index" => "#{i}"}
        {:ok, _} = ConvergeContext.append("source", "facts", "payload-#{i}", metadata)
      end

      # 2. Verify entries
      {:ok, source_entries, source_seq} = ConvergeContext.get("source")
      assert length(source_entries) == 10
      assert source_seq == 10

      # 3. Create snapshot
      {:ok, blob, snap_seq, meta} = ConvergeContext.snapshot("source")
      assert snap_seq == 10
      assert meta.entry_count == 10

      # 4. Load into new context
      {:ok, load_count, load_seq} = ConvergeContext.load("target", blob)
      assert load_count == 10
      assert load_seq == 10

      # 5. Verify target has same entries
      {:ok, target_entries, target_seq} = ConvergeContext.get("target")
      assert length(target_entries) == 10
      assert target_seq == 10

      # 6. Verify payloads match
      source_payloads = Enum.map(source_entries, & &1.payload) |> Enum.sort()
      target_payloads = Enum.map(target_entries, & &1.payload) |> Enum.sort()
      assert source_payloads == target_payloads
    end

    test "incremental sync with after_sequence" do
      # Initial entries
      for i <- 1..5, do: ConvergeContext.append("ctx", "facts", "initial-#{i}")

      # Sync point
      {:ok, _, sync_seq} = ConvergeContext.get("ctx")
      assert sync_seq == 5

      # Add more entries
      for i <- 6..10, do: ConvergeContext.append("ctx", "facts", "new-#{i}")

      # Get only new entries
      {:ok, new_entries, latest_seq} = ConvergeContext.get("ctx", after_sequence: sync_seq)

      assert length(new_entries) == 5
      assert latest_seq == 10
      assert Enum.all?(new_entries, &String.starts_with?(&1.payload, "new-"))
    end

    test "filtering by key type" do
      # Add mixed entries
      ConvergeContext.append("ctx", "facts", "fact-1")
      ConvergeContext.append("ctx", "intents", "intent-1")
      ConvergeContext.append("ctx", "facts", "fact-2")
      ConvergeContext.append("ctx", "traces", "trace-1")
      ConvergeContext.append("ctx", "facts", "fact-3")

      # Filter by type
      {:ok, facts, _} = ConvergeContext.get("ctx", key: "facts")
      {:ok, intents, _} = ConvergeContext.get("ctx", key: "intents")
      {:ok, traces, _} = ConvergeContext.get("ctx", key: "traces")

      assert length(facts) == 3
      assert length(intents) == 1
      assert length(traces) == 1
    end

    test "pagination with limit" do
      for i <- 1..100, do: ConvergeContext.append("ctx", "facts", "p#{i}")

      # Page through results
      {:ok, page1, _} = ConvergeContext.get("ctx", limit: 25)
      {:ok, page2, _} = ConvergeContext.get("ctx", after_sequence: 25, limit: 25)
      {:ok, page3, _} = ConvergeContext.get("ctx", after_sequence: 50, limit: 25)
      {:ok, page4, _} = ConvergeContext.get("ctx", after_sequence: 75, limit: 25)

      assert length(page1) == 25
      assert length(page2) == 25
      assert length(page3) == 25
      assert length(page4) == 25

      # No overlap
      all_seqs =
        Enum.flat_map([page1, page2, page3, page4], &Enum.map(&1, fn e -> e.sequence end))

      assert length(all_seqs) == length(Enum.uniq(all_seqs))
    end
  end
end
