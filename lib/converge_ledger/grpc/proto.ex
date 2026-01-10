defmodule Converge.Context.V1.Entry do
  @moduledoc """
  Proto message: Entry
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:id, 1, type: :string)
  field(:key, 2, type: :string)
  field(:payload, 3, type: :bytes)
  field(:sequence, 4, type: :uint64)
  field(:appended_at_ns, 5, type: :uint64)
  field(:metadata, 6, repeated: true, type: Converge.Context.V1.Entry.MetadataEntry, map: true)

  defmodule MetadataEntry do
    @moduledoc false
    use Protobuf, map: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

    field(:key, 1, type: :string)
    field(:value, 2, type: :string)
  end
end

defmodule Converge.Context.V1.AppendRequest do
  @moduledoc """
  Proto message: AppendRequest
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:context_id, 1, type: :string)
  field(:key, 2, type: :string)
  field(:payload, 3, type: :bytes)

  field(:metadata, 4,
    repeated: true,
    type: Converge.Context.V1.AppendRequest.MetadataEntry,
    map: true
  )

  defmodule MetadataEntry do
    @moduledoc false
    use Protobuf, map: true, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

    field(:key, 1, type: :string)
    field(:value, 2, type: :string)
  end
end

defmodule Converge.Context.V1.AppendResponse do
  @moduledoc """
  Proto message: AppendResponse
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:entry, 1, type: Converge.Context.V1.Entry)
end

defmodule Converge.Context.V1.GetRequest do
  @moduledoc """
  Proto message: GetRequest
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:context_id, 1, type: :string)
  field(:key, 2, type: :string)
  field(:after_sequence, 3, type: :uint64)
  field(:limit, 4, type: :uint32)
end

defmodule Converge.Context.V1.GetResponse do
  @moduledoc """
  Proto message: GetResponse
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:entries, 1, repeated: true, type: Converge.Context.V1.Entry)
  field(:latest_sequence, 2, type: :uint64)
end

defmodule Converge.Context.V1.SnapshotRequest do
  @moduledoc """
  Proto message: SnapshotRequest
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:context_id, 1, type: :string)
end

defmodule Converge.Context.V1.SnapshotMetadata do
  @moduledoc """
  Proto message: SnapshotMetadata
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:created_at_ns, 1, type: :uint64)
  field(:entry_count, 2, type: :uint64)
  field(:version, 3, type: :uint32)
end

defmodule Converge.Context.V1.SnapshotResponse do
  @moduledoc """
  Proto message: SnapshotResponse
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:snapshot, 1, type: :bytes)
  field(:sequence, 2, type: :uint64)
  field(:metadata, 3, type: Converge.Context.V1.SnapshotMetadata)
end

defmodule Converge.Context.V1.LoadRequest do
  @moduledoc """
  Proto message: LoadRequest
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:context_id, 1, type: :string)
  field(:snapshot, 2, type: :bytes)
  field(:fail_if_exists, 3, type: :bool)
end

defmodule Converge.Context.V1.LoadResponse do
  @moduledoc """
  Proto message: LoadResponse
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:entries_restored, 1, type: :uint64)
  field(:latest_sequence, 2, type: :uint64)
end

defmodule Converge.Context.V1.WatchRequest do
  @moduledoc """
  Proto message: WatchRequest
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:context_id, 1, type: :string)
  field(:key, 2, type: :string)
  field(:from_sequence, 3, type: :uint64)
end

defmodule Converge.Context.V1.WatchEvent do
  @moduledoc """
  Proto message: WatchEvent
  """

  use Protobuf, protoc_gen_elixir_version: "0.13.0", syntax: :proto3

  field(:entry, 1, type: Converge.Context.V1.Entry)
end

defmodule Converge.Context.V1.ContextService.Service do
  @moduledoc """
  gRPC service definition for ContextService.
  """

  use GRPC.Service,
    name: "converge.context.v1.ContextService",
    protoc_gen_elixir_version: "0.13.0"

  rpc(:Append, Converge.Context.V1.AppendRequest, Converge.Context.V1.AppendResponse)
  rpc(:Get, Converge.Context.V1.GetRequest, Converge.Context.V1.GetResponse)
  rpc(:Snapshot, Converge.Context.V1.SnapshotRequest, Converge.Context.V1.SnapshotResponse)
  rpc(:Load, Converge.Context.V1.LoadRequest, Converge.Context.V1.LoadResponse)

  rpc(:Watch, Converge.Context.V1.WatchRequest, stream(Converge.Context.V1.WatchEvent))
end
