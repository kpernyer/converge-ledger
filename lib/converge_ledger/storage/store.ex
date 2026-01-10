defmodule ConvergeLedger.Storage.Store do
  @moduledoc """
  Mnesia-backed append-only context store.

  This store is derivative, not authoritative:
  - It remembers what already happened
  - It never decides or coordinates convergence
  - It may lose data (engine can regenerate)
  - It never mutates or rewrites history

  The Rust engine remains the single semantic authority.
  """

  alias ConvergeLedger.Entry
  alias ConvergeLedger.Storage.Schema

  require Logger

  # Snapshot version for forward compatibility
  @snapshot_version 1

  @doc """
  Appends an entry to the context.

  Returns `{:ok, entry}` with the full entry including assigned sequence number,
  or `{:error, reason}` on failure.
  """
  def append(context_id, key, payload, metadata \\ %{}) 
      when is_binary(context_id) and is_binary(key) and is_binary(payload) and is_map(metadata) do
    result = 
      :mnesia.transaction(fn ->
        sequence = next_sequence(context_id)
        entry = Entry.new(context_id, key, payload, sequence, metadata)
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
        metadata = %{
          created_at_ns: System.os_time(:nanosecond),
          entry_count: length(entries),
          version: @snapshot_version
        }

        snapshot_data = %{
          version: @snapshot_version,
          context_id: context_id,
          entries: Enum.map(entries, &entry_to_map/1),
          sequence: latest_seq
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

  Returns `{:ok, entries_restored, latest_sequence}` or `{:error, reason}`.
  """
  def load(context_id, snapshot_blob, fail_if_exists \\ false)
      when is_binary(context_id) and is_binary(snapshot_blob) do
    with {:ok, snapshot_data} <- deserialize_snapshot(snapshot_blob),
         :ok <- validate_snapshot(snapshot_data),
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
      metadata: entry.metadata
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
      metadata: map.metadata
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

  defp do_load(context_id, snapshot_data) do
    generate_new_ids = context_id != snapshot_data.context_id
    entries = Enum.map(snapshot_data.entries, &map_to_entry(context_id, &1, generate_new_ids))
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
