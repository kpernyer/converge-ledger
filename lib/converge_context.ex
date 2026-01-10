defmodule ConvergeContext do
  @moduledoc """
  Append-only shared context store for Converge.

  This service is derivative, not authoritative:
  - It remembers what already happened
  - It never decides or coordinates convergence
  - It may lose data (the Rust engine can regenerate)
  - It never mutates or rewrites history

  The Rust engine remains the single semantic authority.

  ## API

  The minimal API is exposed via gRPC:

  - `Append(context_id, key, payload)` - Add an entry
  - `Get(context_id)` - Retrieve all entries
  - `Snapshot(context_id)` - Create a portable snapshot
  - `Load(context_id, blob)` - Restore from a snapshot
  - `Watch(context_id)` - Stream new entries (optional)

  ## Non-Goals

  This service explicitly does NOT support:

  - Conditional updates
  - Transactions across contexts
  - Locks
  - Conflict resolution
  - Branching
  - Deletes

  If you need any of these, the design is wrong.

  ## Usage

  The service starts automatically when the application starts.
  Connect via gRPC on port 50051 (or `GRPC_PORT` env var).

  ```elixir
  # Local Elixir API (for testing)
  {:ok, entry} = ConvergeContext.append("my-context", "facts", payload)
  {:ok, entries, seq} = ConvergeContext.get("my-context")
  {:ok, blob, seq, meta} = ConvergeContext.snapshot("my-context")
  {:ok, count, seq} = ConvergeContext.load("my-context", blob)
  ```
  """

  alias ConvergeContext.Storage.Store

  @doc """
  Appends an entry to a context.

  Returns `{:ok, entry}` with the full entry including assigned sequence number.
  """
  defdelegate append(context_id, key, payload, metadata \\ %{}), to: Store

  @doc """
  Gets entries from a context.

  Options:
  - `:key` - filter by context key
  - `:after_sequence` - only entries with sequence > this value
  - `:limit` - maximum number of entries to return

  Returns `{:ok, entries, latest_sequence}`.
  """
  defdelegate get(context_id, opts \\ []), to: Store

  @doc """
  Creates a snapshot of the entire context.

  Returns `{:ok, snapshot_blob, sequence, metadata}`.
  """
  defdelegate snapshot(context_id), to: Store

  @doc """
  Loads a context from a snapshot blob.

  If `fail_if_exists` is true, returns an error if the context already has entries.

  Returns `{:ok, entries_restored, latest_sequence}`.
  """
  defdelegate load(context_id, snapshot_blob, fail_if_exists \\ false), to: Store

  @doc """
  Gets the current sequence number for a context.

  Returns `{:ok, sequence}`.
  """
  defdelegate current_sequence(context_id), to: Store
end
