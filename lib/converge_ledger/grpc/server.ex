defmodule ConvergeLedger.Grpc.Server do
  @moduledoc """
  gRPC server implementation for ContextService.

  This server provides append-only context storage with:
  - Append: Add entries to a context
  - Get: Retrieve entries from a context
  - Snapshot: Create a portable snapshot
  - Load: Restore from a snapshot
  - Watch: Stream new entries as they are appended

  The server is derivative, not authoritative. It remembers what
  already happened but never decides or coordinates convergence.
  """

  use GRPC.Server, service: Converge.Context.V1.ContextService.Service

  alias Converge.Context.V1
  alias ConvergeLedger.Entry
  alias ConvergeLedger.Storage.Store
  alias ConvergeLedger.WatchRegistry

  require Logger

  @doc """
  Appends an entry to the context.
  """
  def append(request, _stream) do
    Logger.info("Append request for context: #{request.context_id}, key: #{request.key}")

    metadata = Map.new(request.metadata || [])

    case Store.append(request.context_id, request.key, request.payload, metadata) do
      {:ok, entry} ->
        # Notify watchers
        WatchRegistry.notify(entry)

        %V1.AppendResponse{
          entry: entry_to_proto(entry)
        }

      {:error, :payload_too_large} ->
        raise GRPC.RPCError,
          status: :resource_exhausted,
          message: "Payload exceeds maximum allowed size"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: "Append failed: #{inspect(reason)}"
    end
  end

  @doc """
  Gets entries from a context.
  """
  def get(request, _stream) do
    Logger.info("Get request for context: #{request.context_id}")

    opts =
      []
      |> maybe_add_opt(:key, request.key)
      |> maybe_add_opt(:after_sequence, request.after_sequence)
      |> maybe_add_opt(:limit, request.limit)

    case Store.get(request.context_id, opts) do
      {:ok, entries, latest_seq} ->
        %V1.GetResponse{
          entries: Enum.map(entries, &entry_to_proto/1),
          latest_sequence: latest_seq
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: "Get failed: #{inspect(reason)}"
    end
  end

  @doc """
  Creates a snapshot of the context.
  """
  def snapshot(request, _stream) do
    Logger.info("Snapshot request for context: #{request.context_id}")

    case Store.snapshot(request.context_id) do
      {:ok, blob, sequence, metadata} ->
        %V1.SnapshotResponse{
          snapshot: blob,
          sequence: sequence,
          metadata: %V1.SnapshotMetadata{
            created_at_ns: metadata.created_at_ns,
            entry_count: metadata.entry_count,
            version: metadata.version
          }
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: "Snapshot failed: #{inspect(reason)}"
    end
  end

  @doc """
  Loads a context from a snapshot.
  """
  def load(request, _stream) do
    Logger.info("Load request for context: #{request.context_id}")

    case Store.load(request.context_id, request.snapshot, request.fail_if_exists) do
      {:ok, count, latest_seq} ->
        %V1.LoadResponse{
          entries_restored: count,
          latest_sequence: latest_seq
        }

      {:error, :context_already_exists} ->
        raise GRPC.RPCError,
          status: :already_exists,
          message: "Context already has entries"

      {:error, :invalid_snapshot_format} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "Invalid snapshot format"

      {:error, {:unsupported_snapshot_version, version}} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "Unsupported snapshot version: #{version}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :internal, message: "Load failed: #{inspect(reason)}"
    end
  end

  @doc """
  Watches for new entries in a context.
  """
  def watch(request, stream) do
    Logger.info("Watch request for context: #{request.context_id}")

    context_id = request.context_id
    key_filter = if request.key == "", do: nil, else: request.key
    from_sequence = request.from_sequence

    # First, send any existing entries after from_sequence
    case Store.get(context_id, key: key_filter, after_sequence: from_sequence) do
      {:ok, entries, _latest_seq} ->
        Enum.each(entries, fn entry ->
          GRPC.Server.send_reply(stream, %V1.WatchEvent{entry: entry_to_proto(entry)})
        end)

      {:error, reason} ->
        Logger.error("Failed to get initial entries for watch: #{inspect(reason)}")
    end

    # Subscribe to new entries
    {:ok, _ref} = WatchRegistry.subscribe(context_id, key_filter)

    # Enter receive loop
    watch_loop(stream)
  end

  defp watch_loop(stream) do
    receive do
      {:context_entry, entry} ->
        GRPC.Server.send_reply(stream, %V1.WatchEvent{entry: entry_to_proto(entry)})
        watch_loop(stream)

      {:grpc_closed} ->
        Logger.info("Watch stream closed by client")
        :ok

      other ->
        Logger.warning("Unexpected message in watch loop: #{inspect(other)}")
        watch_loop(stream)
    end
  end

  # Conversion helpers

  defp entry_to_proto(%Entry{} = entry) do
    %V1.Entry{
      id: entry.id,
      key: entry.key,
      payload: entry.payload,
      sequence: entry.sequence,
      appended_at_ns: entry.appended_at_ns,
      metadata: Enum.map(entry.metadata, fn {k, v} -> {to_string(k), to_string(v)} end)
    }
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, _key, 0), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
