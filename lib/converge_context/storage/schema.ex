defmodule ConvergeContext.Storage.Schema do
  @moduledoc """
  Mnesia schema definitions for the context store.

  All table names are centralized here. Never hardcode table names elsewhere.
  """

  require Logger

  # Table names
  @entries_table :context_entries
  @sequences_table :context_sequences

  @doc """
  Returns the entries table name.
  """
  def entries_table, do: @entries_table

  @doc """
  Returns the sequences table name.
  """
  def sequences_table, do: @sequences_table

  @doc """
  Initializes the Mnesia schema and creates tables.

  Safe to call multiple times (idempotent).
  """
  def init do
    with :ok <- ensure_schema_created(),
         :ok <- ensure_mnesia_started(),
         :ok <- ensure_tables_created() do
      Logger.info("Mnesia schema initialized successfully")
      :ok
    end
  end

  @doc """
  Clears all data from all tables. Use with caution.
  """
  def clear_all do
    :mnesia.clear_table(@entries_table)
    :mnesia.clear_table(@sequences_table)
    :ok
  end

  defp ensure_schema_created do
    # Schema creation only needed for disc_copies (distributed nodes)
    # For ram_copies (nonode@nohost), skip schema creation
    if node() == :nonode@nohost do
      :ok
    else
      case :mnesia.create_schema([node()]) do
        :ok -> :ok
        {:error, {_, {:already_exists, _}}} -> :ok
        {:error, reason} -> {:error, {:schema_creation_failed, reason}}
      end
    end
  end

  defp ensure_mnesia_started do
    case :mnesia.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:mnesia_start_failed, reason}}
    end
  end

  defp ensure_tables_created do
    with :ok <- create_entries_table(),
         :ok <- create_sequences_table() do
      :ok
    end
  end

  defp create_entries_table do
    # Entry record: {table, {context_id, sequence}, key, payload, appended_at_ns, metadata}
    # Composite key: {context_id, sequence} for efficient range queries
    attrs = [
      attributes: [:id, :context_id, :key, :payload, :sequence, :appended_at_ns, :metadata],
      index: [:context_id, :key],
      type: :set
    ]

    attrs = attrs ++ storage_type()

    case :mnesia.create_table(@entries_table, attrs) do
      {:atomic, :ok} ->
        Logger.info("Created table #{@entries_table}")
        :ok

      {:aborted, {:already_exists, @entries_table}} ->
        :ok

      {:aborted, reason} ->
        {:error, {:table_creation_failed, @entries_table, reason}}
    end
  end

  defp create_sequences_table do
    # Sequence counter per context_id
    # Record: {table, context_id, current_sequence}
    attrs = [
      attributes: [:context_id, :current_sequence],
      type: :set
    ]

    attrs = attrs ++ storage_type()

    case :mnesia.create_table(@sequences_table, attrs) do
      {:atomic, :ok} ->
        Logger.info("Created table #{@sequences_table}")
        :ok

      {:aborted, {:already_exists, @sequences_table}} ->
        :ok

      {:aborted, reason} ->
        {:error, {:table_creation_failed, @sequences_table, reason}}
    end
  end

  # Use ram_copies as primary storage
  defp storage_type do
    [ram_copies: [node()]]
  end
end
