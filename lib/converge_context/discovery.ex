defmodule ConvergeContext.Discovery do
  @moduledoc """
  Handles service discovery and grouping using Erlang's `pg` (Process Groups).

  Allows processes to:
  - Register as serving a specific context ("domain").
  - Discover other nodes/processes serving that context.
  - Broadcast messages to the group.
  """

  @doc """
  Registers the current process as a member of the group serving `context_id`.
  """
  def join(context_id) when is_binary(context_id) do
    :pg.join(group_name(context_id), self())
  end

  @doc """
  Leaves the group serving `context_id`.
  """
  def leave(context_id) when is_binary(context_id) do
    :pg.leave(group_name(context_id), self())
  end

  @doc """
  Returns a list of PIDs serving `context_id` across the cluster.
  """
  def members(context_id) when is_binary(context_id) do
    :pg.get_members(group_name(context_id))
  end

  @doc """
  Returns a list of local PIDs serving `context_id`.
  """
  def local_members(context_id) when is_binary(context_id) do
    :pg.get_local_members(group_name(context_id))
  end

  @doc """
  Broadcasts a message to all members serving `context_id` (including self).
  """
  def broadcast(context_id, message) when is_binary(context_id) do
    members(context_id)
    |> Enum.each(fn pid -> send(pid, message) end)
  end

  defp group_name(context_id), do: {:context, context_id}
end
