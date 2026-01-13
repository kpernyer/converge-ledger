defmodule ConvergeLedger.Storage.Store do
  @moduledoc """
  Mnesia-backed append-only context store.

  This store is derivative, not authoritative:
  - It remembers what already happened
  - It never decides or coordinates convergence
  - It may lose data (engine can regenerate)
  - It never mutates or rewrites history

  The Rust engine remains the single semantic authority.

  ## Integrity Features

  - **Merkle roots**: Snapshots include a Merkle root for tamper detection
  - **Lamport clocks**: Optional causal ordering of entries
  - **Content hashes**: Optional integrity verification per entry
  """

  alias ConvergeLedger.Entry
  alias ConvergeLedger.Storage.Schema
  alias ConvergeLedger.Integrity.MerkleTree

  require Logger

  # Snapshot version for forward compatibility
  # Version 2 adds Merkle root for integrity verification
  @snapshot_version 2

  @doc """
  Appends an entry to the context.

  Each entry is assigned:
  - A sequence number (monotonically increasing per context)
  - A Lamport clock timestamp (for causal ordering across contexts)
  - A content hash (SHA-256 for integrity verification)

  Returns `{:ok, entry}` with the full entry including assigned sequence number,
  or `{:error, reason}` on failure.
  """
  def append(context_id, key, payload, metadata \\ %{})
      when is_binary(context_id) and is_binary(key) and is_binary(payload) and is_map(metadata) do
    result =
      :mnesia.transaction(fn ->
        sequence = next_sequence(context_id)
        lamport_time = tick_lamport_clock(context_id)
        entry = Entry.new(context_id, key, payload, sequence, metadata, lamport_clock: lamport_time)
        # Compute content hash for integrity verification
        content_hash = MerkleTree.hash_entry(entry)
        entry = %{entry | content_hash: content_hash}
        :mnesia.write(Entry.to_record(entry))
        entry
      end)

    case result do
      {:atomic, entry} ->
        {:ok, entry}

      {:aborted, reason} ->
        Logger.error("Failed to append entry: #{inspect(reason)}")
        {:error, {:append_failed, reason}}
    end
  end

  @doc """
  Appends an entry with a received Lamport timestamp.

  Use this when receiving entries from another context/node to maintain
  causal ordering. The local clock will be updated to max(local, received) + 1.

  Returns `{:ok, entry}` or `{:error, reason}`.
  """
  def append_with_received_time(context_id, key, payload, received_lamport_time, metadata \\ %{})
      when is_binary(context_id) and is_binary(key) and is_binary(payload) and
             is_integer(received_lamport_time) and is_map(metadata) do
    result =
      :mnesia.transaction(fn ->
        sequence = next_sequence(context_id)
        lamport_time = update_lamport_clock(context_id, received_lamport_time)
        entry = Entry.new(context_id, key, payload, sequence, metadata, lamport_clock: lamport_time)
        content_hash = MerkleTree.hash_entry(entry)
        entry = %{entry | content_hash: content_hash}
        :mnesia.write(Entry.to_record(entry))
        entry
      end)

    case result do
      {:atomic, entry} ->
        {:ok, entry}

      {:aborted, reason} ->
        Logger.error("Failed to append entry with received time: #{inspect(reason)}")
        {:error, {:append_failed, reason}}
    end
  end

  @doc """
  Gets entries from a context.

  Options:
  - `:key` - filter by context key
  - `:after_sequence` - only entries with sequence > this value
  - `:limit` - maximum number of entries to return

  Returns `{:ok, entries, latest_sequence}` or `{:error, reason}`.
  """
  def get(context_id, opts \\ []) when is_binary(context_id) do
    key_filter = Keyword.get(opts, :key)
    after_seq = Keyword.get(opts, :after_sequence, 0)
    limit = Keyword.get(opts, :limit, 0)

    result =
      :mnesia.transaction(fn ->
        entries = fetch_entries(context_id, key_filter, after_seq, limit)
        latest_seq = get_current_sequence(context_id)
        {entries, latest_seq}
      end)

    case result do
      {:atomic, {entries, latest_seq}} ->
        {:ok, entries, latest_seq}

      {:aborted, reason} ->
        Logger.error("Failed to get entries: #{inspect(reason)}")
        {:error, {:get_failed, reason}}
    end
  end

  @doc """
  Creates a snapshot of the entire context.

  Returns `{:ok, snapshot_blob, sequence, metadata}` or `{:error, reason}`.
  """
  def snapshot(context_id) when is_binary(context_id) do
    result =
      :mnesia.transaction(fn ->
        entries = fetch_all_entries(context_id)
        latest_seq = get_current_sequence(context_id)
        {entries, latest_seq}
      end)

    case result do
      {:atomic, {entries, latest_seq}} ->
        # Compute Merkle root for integrity verification
        merkle_root = MerkleTree.compute_root_from_entries(entries)

        metadata = %{
          created_at_ns: System.os_time(:nanosecond),
          entry_count: length(entries),
          version: @snapshot_version,
          merkle_root: MerkleTree.to_hex(merkle_root)
        }

        snapshot_data = %{
          version: @snapshot_version,
          context_id: context_id,
          entries: Enum.map(entries, &entry_to_map/1),
          sequence: latest_seq,
          merkle_root: merkle_root
        }

        blob = :erlang.term_to_binary(snapshot_data, [:compressed])
        {:ok, blob, latest_seq, metadata}

      {:aborted, reason} ->
        Logger.error("Failed to create snapshot: #{inspect(reason)}")
        {:error, {:snapshot_failed, reason}}
    end
  end

  @doc """
  Loads a context from a snapshot blob.

  If `fail_if_exists` is true, returns an error if the context already has entries.

  Options:
  - `:verify_integrity` - If true, verifies Merkle root before loading (default: true)

  Returns `{:ok, entries_restored, latest_sequence}` or `{:error, reason}`.
  """
  def load(context_id, snapshot_blob, opts \\ [])

  def load(context_id, snapshot_blob, fail_if_exists) when is_boolean(fail_if_exists) do
    # Backward compatibility: treat boolean as fail_if_exists option
    load(context_id, snapshot_blob, fail_if_exists: fail_if_exists)
  end

  def load(context_id, snapshot_blob, opts) when is_binary(context_id) and is_binary(snapshot_blob) and is_list(opts) do
    fail_if_exists = Keyword.get(opts, :fail_if_exists, false)
    verify_integrity = Keyword.get(opts, :verify_integrity, true)

    with {:ok, snapshot_data} <- deserialize_snapshot(snapshot_blob),
         :ok <- validate_snapshot(snapshot_data),
         :ok <- maybe_verify_integrity(snapshot_data, verify_integrity),
         :ok <- check_context_empty(context_id, fail_if_exists) do
      do_load(context_id, snapshot_data)
    end
  end

  @doc """
  Gets the current sequence number for a context.

  Returns `{:ok, sequence}` or `{:error, reason}`.
  """
  def current_sequence(context_id) when is_binary(context_id) do
    result =
      :mnesia.transaction(fn ->
        get_current_sequence(context_id)
      end)

    case result do
      {:atomic, seq} -> {:ok, seq}
      {:aborted, reason} -> {:error, {:sequence_failed, reason}}
    end
  end

  @doc """
  Gets the current Lamport clock time for a context.

  Returns `{:ok, lamport_time}` or `{:error, reason}`.
  """
  def current_lamport_time(context_id) when is_binary(context_id) do
    result =
      :mnesia.transaction(fn ->
        get_current_lamport_time(context_id)
      end)

    case result do
      {:atomic, time} -> {:ok, time}
      {:aborted, reason} -> {:error, {:lamport_time_failed, reason}}
    end
  end

  # Private functions

  defp next_sequence(context_id) do
    table = Schema.sequences_table()

    case :mnesia.read(table, context_id) do
      [] ->
        :mnesia.write({table, context_id, 1})
        1

      [{^table, ^context_id, current}] ->
        next = current + 1
        :mnesia.write({table, context_id, next})
        next
    end
  end

  defp get_current_sequence(context_id) do
    table = Schema.sequences_table()

    case :mnesia.read(table, context_id) do
      [] -> 0
      [{^table, ^context_id, current}] -> current
    end
  end

  # Lamport clock functions - must be called within a transaction

  defp get_current_lamport_time(context_id) do
    table = Schema.lamport_clocks_table()

    case :mnesia.read(table, context_id) do
      [] -> 0
      [{^table, ^context_id, current}] -> current
    end
  end

  defp tick_lamport_clock(context_id) do
    table = Schema.lamport_clocks_table()

    case :mnesia.read(table, context_id) do
      [] ->
        # First event in this context
        :mnesia.write({table, context_id, 1})
        1

      [{^table, ^context_id, current}] ->
        new_time = current + 1
        :mnesia.write({table, context_id, new_time})
        new_time
    end
  end

  defp update_lamport_clock(context_id, received_time) do
    table = Schema.lamport_clocks_table()

    local_time =
      case :mnesia.read(table, context_id) do
        [] -> 0
        [{^table, ^context_id, current}] -> current
      end

    # Lamport rule: max(local, received) + 1
    new_time = max(local_time, received_time) + 1
    :mnesia.write({table, context_id, new_time})
    new_time
  end

  defp fetch_entries(context_id, key_filter, after_seq, limit) do
    table = Schema.entries_table()

    # Use index on context_id
    entries =
      :mnesia.index_read(table, context_id, :context_id)
      |> Enum.map(&Entry.from_record/1)
      |> Enum.filter(fn entry ->
        entry.sequence > after_seq and
          (is_nil(key_filter) or entry.key == key_filter)
      end)
      |> Enum.sort_by(& &1.sequence)

    if limit > 0 do
      Enum.take(entries, limit)
    else
      entries
    end
  end

  defp fetch_all_entries(context_id) do
    table = Schema.entries_table()

    :mnesia.index_read(table, context_id, :context_id)
    |> Enum.map(&Entry.from_record/1)
    |> Enum.sort_by(& &1.sequence)
  end

  defp entry_to_map(%Entry{} = entry) do
    %{
      id: entry.id,
      key: entry.key,
      payload: entry.payload,
      sequence: entry.sequence,
      appended_at_ns: entry.appended_at_ns,
      metadata: entry.metadata,
      lamport_clock: entry.lamport_clock,
      content_hash: entry.content_hash
    }
  end

  defp map_to_entry(context_id, map, generate_new_ids) do
    id = if generate_new_ids, do: generate_id(), else: map.id

    %Entry{
      id: id,
      context_id: context_id,
      key: map.key,
      payload: map.payload,
      sequence: map.sequence,
      appended_at_ns: map.appended_at_ns,
      metadata: map.metadata,
      lamport_clock: Map.get(map, :lamport_clock),
      content_hash: Map.get(map, :content_hash)
    }
  end

  defp deserialize_snapshot(blob) do
    try do
      {:ok, :erlang.binary_to_term(blob, [:safe])}
    rescue
      _ -> {:error, :invalid_snapshot_format}
    end
  end

  defp validate_snapshot(%{version: version}) when version > @snapshot_version do
    {:error, {:unsupported_snapshot_version, version}}
  end

  defp validate_snapshot(%{version: _, entries: entries}) when is_list(entries), do: :ok
  defp validate_snapshot(_), do: {:error, :invalid_snapshot_structure}

  defp check_context_empty(context_id, true = _fail_if_exists) do
    case current_sequence(context_id) do
      {:ok, 0} -> :ok
      {:ok, _} -> {:error, :context_already_exists}
      error -> error
    end
  end

  defp check_context_empty(_context_id, false), do: :ok

  defp maybe_verify_integrity(_snapshot_data, false), do: :ok

  defp maybe_verify_integrity(%{merkle_root: nil}, true) do
    # No Merkle root in snapshot (v1 snapshot), skip verification
    :ok
  end

  defp maybe_verify_integrity(%{merkle_root: stored_root, entries: entries, context_id: context_id}, true) do
    # Reconstruct entries and verify Merkle root
    computed_root =
      entries
      |> Enum.map(fn map ->
        %Entry{
          id: map.id,
          context_id: context_id,
          key: map.key,
          payload: map.payload,
          sequence: map.sequence,
          appended_at_ns: map.appended_at_ns,
          metadata: map.metadata
        }
      end)
      |> MerkleTree.compute_root_from_entries()

    if computed_root == stored_root do
      :ok
    else
      {:error, :integrity_verification_failed}
    end
  end

  defp maybe_verify_integrity(_snapshot_data, true) do
    # Snapshot doesn't have merkle_root field (old format)
    :ok
  end

  defp do_load(context_id, snapshot_data) do
    context_changed = context_id != snapshot_data.context_id
    generate_new_ids = context_changed

    entries =
      snapshot_data.entries
      |> Enum.map(&map_to_entry(context_id, &1, generate_new_ids))
      |> Enum.map(fn entry ->
        # Recompute content hash if context changed (hash includes context_id)
        if context_changed and entry.content_hash != nil do
          %{entry | content_hash: MerkleTree.hash_entry(entry)}
        else
          entry
        end
      end)

    max_seq = snapshot_data.sequence

    result =
      :mnesia.transaction(fn ->
        # Write all entries
        Enum.each(entries, fn entry ->
          :mnesia.write(Entry.to_record(entry))
        end)

        # Update sequence counter
        table = Schema.sequences_table()
        current = get_current_sequence(context_id)

        if max_seq > current do
          :mnesia.write({table, context_id, max_seq})
        end

        length(entries)
      end)

    case result do
      {:atomic, count} ->
        {:ok, count, max_seq}

      {:aborted, reason} ->
        Logger.error("Failed to load snapshot: #{inspect(reason)}")
        {:error, {:load_failed, reason}}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
