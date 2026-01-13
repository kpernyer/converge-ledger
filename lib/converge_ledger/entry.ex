defmodule ConvergeLedger.Entry do
  @moduledoc """
  Represents a single append-only entry in a context.

  Entries are immutable once created. The only way to "change" data
  is to append a new entry that supersedes it.

  ## Integrity Fields

  - `lamport_clock`: Optional Lamport timestamp for causal ordering.
    When set, provides happened-before relationships across entries.
  - `content_hash`: Optional SHA-256 hash of the entry content.
    Computed automatically when integrity tracking is enabled.
  """

  @enforce_keys [:id, :context_id, :key, :payload, :sequence, :appended_at_ns]
  defstruct [
    :id,
    :context_id,
    :key,
    :payload,
    :sequence,
    :appended_at_ns,
    :lamport_clock,
    :content_hash,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t(),
          key: String.t(),
          payload: binary(),
          sequence: non_neg_integer(),
          appended_at_ns: non_neg_integer(),
          lamport_clock: non_neg_integer() | nil,
          content_hash: binary() | nil,
          metadata: map()
        }

  @doc """
  Creates a new entry with an auto-generated ID and timestamp.

  ## Options

  - `:lamport_clock` - Lamport timestamp for causal ordering
  - `:content_hash` - SHA-256 hash for integrity verification
  """
  def new(context_id, key, payload, sequence, metadata \\ %{}, opts \\ [])

  def new(context_id, key, payload, sequence, metadata, opts)
      when is_binary(context_id) and is_binary(key) and is_binary(payload) and
             is_integer(sequence) and is_map(metadata) and is_list(opts) do
    %__MODULE__{
      id: generate_id(),
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: System.os_time(:nanosecond),
      metadata: metadata,
      lamport_clock: Keyword.get(opts, :lamport_clock),
      content_hash: Keyword.get(opts, :content_hash)
    }
  end

  @doc """
  Converts an entry to a Mnesia record tuple.

  The record format includes integrity fields (lamport_clock, content_hash).
  """
  def to_record(%__MODULE__{} = entry) do
    {
      ConvergeLedger.Storage.Schema.entries_table(),
      entry.id,
      entry.context_id,
      entry.key,
      entry.payload,
      entry.sequence,
      entry.appended_at_ns,
      entry.metadata,
      entry.lamport_clock,
      entry.content_hash
    }
  end

  @doc """
  Converts a Mnesia record tuple to an Entry struct.

  Handles both old format (8 fields) and new format (10 fields with integrity).
  """
  def from_record({_table, id, context_id, key, payload, sequence, appended_at_ns, metadata}) do
    # Legacy format without integrity fields
    %__MODULE__{
      id: id,
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: appended_at_ns,
      metadata: metadata,
      lamport_clock: nil,
      content_hash: nil
    }
  end

  def from_record({_table, id, context_id, key, payload, sequence, appended_at_ns, metadata, lamport_clock, content_hash}) do
    # New format with integrity fields
    %__MODULE__{
      id: id,
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: appended_at_ns,
      metadata: metadata,
      lamport_clock: lamport_clock,
      content_hash: content_hash
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
