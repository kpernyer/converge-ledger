defmodule ConvergeContext.Entry do
  @moduledoc """
  Represents a single append-only entry in a context.

  Entries are immutable once created. The only way to "change" data
  is to append a new entry that supersedes it.
  """

  @enforce_keys [:id, :context_id, :key, :payload, :sequence, :appended_at_ns]
  defstruct [
    :id,
    :context_id,
    :key,
    :payload,
    :sequence,
    :appended_at_ns,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t(),
          key: String.t(),
          payload: binary(),
          sequence: non_neg_integer(),
          appended_at_ns: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Creates a new entry with an auto-generated ID and timestamp.
  """
  def new(context_id, key, payload, sequence, metadata \\ %{})
      when is_binary(context_id) and is_binary(key) and is_binary(payload) and
             is_integer(sequence) and is_map(metadata) do
    %__MODULE__{
      id: generate_id(),
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: System.os_time(:nanosecond),
      metadata: metadata
    }
  end

  @doc """
  Converts an entry to a Mnesia record tuple.
  """
  def to_record(%__MODULE__{} = entry) do
    {
      ConvergeContext.Storage.Schema.entries_table(),
      entry.id,
      entry.context_id,
      entry.key,
      entry.payload,
      entry.sequence,
      entry.appended_at_ns,
      entry.metadata
    }
  end

  @doc """
  Converts a Mnesia record tuple to an Entry struct.
  """
  def from_record({_table, id, context_id, key, payload, sequence, appended_at_ns, metadata}) do
    %__MODULE__{
      id: id,
      context_id: context_id,
      key: key,
      payload: payload,
      sequence: sequence,
      appended_at_ns: appended_at_ns,
      metadata: metadata
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
