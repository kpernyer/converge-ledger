defmodule ConvergeLedgerTest do
  @moduledoc """
  Integration tests for ConvergeLedger public API.

  Unit tests and property tests are in separate files under test/converge_context/.
  """

  use ExUnit.Case

  alias ConvergeLedger.Storage.Schema

  setup do
    :mnesia.start()
    Schema.init()
    Schema.clear_all()
    :ok
  end

  describe "public API delegation" do
    test "append/4 delegates to Store" do
      {:ok, entry} = ConvergeLedger.append("test-ctx", "facts", "payload")

      assert entry.context_id == "test-ctx"
      assert entry.key == "facts"
      assert entry.payload == "payload"
      assert entry.sequence == 1
    end

    test "get/2 delegates to Store" do
      {:ok, _} = ConvergeLedger.append("test-ctx", "facts", "p1")
      {:ok, _} = ConvergeLedger.append("test-ctx", "facts", "p2")

      {:ok, entries, seq} = ConvergeLedger.get("test-ctx")

      assert length(entries) == 2
      assert seq == 2
    end

    test "snapshot/1 delegates to Store" do
      {:ok, _} = ConvergeLedger.append("test-ctx", "facts", "payload")

      {:ok, blob, seq, meta} = ConvergeLedger.snapshot("test-ctx")

      assert is_binary(blob)
      assert seq == 1
      assert meta.entry_count == 1
    end

    test "load/3 delegates to Store" do
      {:ok, _} = ConvergeLedger.append("source", "facts", "payload")
      {:ok, blob, _, _} = ConvergeLedger.snapshot("source")

      {:ok, count, seq} = ConvergeLedger.load("target", blob)

      assert count == 1
      assert seq == 1
    end

    test "current_sequence/1 delegates to Store" do
      {:ok, _} = ConvergeLedger.append("test-ctx", "facts", "p1")
      {:ok, _} = ConvergeLedger.append("test-ctx", "facts", "p2")

      {:ok, seq} = ConvergeLedger.current_sequence("test-ctx")

      assert seq == 2
    end
  end

  describe "end-to-end workflow" do
    test "complete append -> get -> snapshot -> load cycle" do
      # 1. Append entries to source context
      for i <- 1..10 do
        metadata = %{"index" => "#{i}"}
        {:ok, _} = ConvergeLedger.append("source", "facts", "payload-#{i}", metadata)
      end

      # 2. Verify entries
      {:ok, source_entries, source_seq} = ConvergeLedger.get("source")
      assert length(source_entries) == 10
      assert source_seq == 10

      # 3. Create snapshot
      {:ok, blob, snap_seq, meta} = ConvergeLedger.snapshot("source")
      assert snap_seq == 10
      assert meta.entry_count == 10

      # 4. Load into new context
      {:ok, load_count, load_seq} = ConvergeLedger.load("target", blob)
      assert load_count == 10
      assert load_seq == 10

      # 5. Verify target has same entries
      {:ok, target_entries, target_seq} = ConvergeLedger.get("target")
      assert length(target_entries) == 10
      assert target_seq == 10

      # 6. Verify payloads match
      source_payloads = Enum.map(source_entries, & &1.payload) |> Enum.sort()
      target_payloads = Enum.map(target_entries, & &1.payload) |> Enum.sort()
      assert source_payloads == target_payloads
    end

    test "incremental sync with after_sequence" do
      # Initial entries
      for i <- 1..5, do: ConvergeLedger.append("ctx", "facts", "initial-#{i}")

      # Sync point
      {:ok, _, sync_seq} = ConvergeLedger.get("ctx")
      assert sync_seq == 5

      # Add more entries
      for i <- 6..10, do: ConvergeLedger.append("ctx", "facts", "new-#{i}")

      # Get only new entries
      {:ok, new_entries, latest_seq} = ConvergeLedger.get("ctx", after_sequence: sync_seq)

      assert length(new_entries) == 5
      assert latest_seq == 10
      assert Enum.all?(new_entries, &String.starts_with?(&1.payload, "new-"))
    end

    test "filtering by key type" do
      # Add mixed entries
      ConvergeLedger.append("ctx", "facts", "fact-1")
      ConvergeLedger.append("ctx", "intents", "intent-1")
      ConvergeLedger.append("ctx", "facts", "fact-2")
      ConvergeLedger.append("ctx", "traces", "trace-1")
      ConvergeLedger.append("ctx", "facts", "fact-3")

      # Filter by type
      {:ok, facts, _} = ConvergeLedger.get("ctx", key: "facts")
      {:ok, intents, _} = ConvergeLedger.get("ctx", key: "intents")
      {:ok, traces, _} = ConvergeLedger.get("ctx", key: "traces")

      assert length(facts) == 3
      assert length(intents) == 1
      assert length(traces) == 1
    end

    test "pagination with limit" do
      for i <- 1..100, do: ConvergeLedger.append("ctx", "facts", "p#{i}")

      # Page through results
      {:ok, page1, _} = ConvergeLedger.get("ctx", limit: 25)
      {:ok, page2, _} = ConvergeLedger.get("ctx", after_sequence: 25, limit: 25)
      {:ok, page3, _} = ConvergeLedger.get("ctx", after_sequence: 50, limit: 25)
      {:ok, page4, _} = ConvergeLedger.get("ctx", after_sequence: 75, limit: 25)

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
