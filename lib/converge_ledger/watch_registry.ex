defmodule ConvergeLedger.WatchRegistry do
  @moduledoc """
  Registry for Watch stream subscribers.

  Manages subscriptions to context updates. When entries are appended,
  this registry notifies all subscribers watching that context.
  """

  use GenServer

  require Logger

  @type context_id :: String.t()
  @type subscriber :: {pid(), reference()}

  # Client API

  @doc """
  Starts the watch registry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @doc """
  Subscribes the calling process to updates for a context.

  Returns `{:ok, ref}` where ref is a monitor reference that will be
  used to clean up if the subscriber crashes.
  """
  def subscribe(context_id, key_filter \\ nil) when is_binary(context_id) do
    GenServer.call(__MODULE__, {:subscribe, context_id, key_filter, self()})
  end

  @doc """
  Unsubscribes the calling process from a context.
  """
  def unsubscribe(context_id) when is_binary(context_id) do
    GenServer.call(__MODULE__, {:unsubscribe, context_id, self()})
  end

  @doc """
  Notifies all subscribers of a new entry.

  Called by the Store after appending an entry.
  """
  def notify(entry) do
    GenServer.cast(__MODULE__, {:notify, entry})
  end

  @doc """
  Returns the number of subscribers for a context.
  """
  def subscriber_count(context_id) when is_binary(context_id) do
    GenServer.call(__MODULE__, {:subscriber_count, context_id})
  end

  # Server callbacks

  @impl true
  def init(:ok) do
    # State: %{context_id => [{pid, ref, key_filter}, ...]}
    {:ok, %{subscriptions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:subscribe, context_id, key_filter, pid}, _from, state) do
    ref = Process.monitor(pid)

    subscription = {pid, ref, key_filter}

    new_subs =
      Map.update(
        state.subscriptions,
        context_id,
        [subscription],
        &[subscription | &1]
      )

    new_monitors = Map.put(state.monitors, ref, {context_id, pid})

    {:reply, {:ok, ref}, %{state | subscriptions: new_subs, monitors: new_monitors}}
  end

  @impl true
  def handle_call({:unsubscribe, context_id, pid}, _from, state) do
    {new_subs, new_monitors} = remove_subscriber(state, context_id, pid)
    {:reply, :ok, %{state | subscriptions: new_subs, monitors: new_monitors}}
  end

  @impl true
  def handle_call({:subscriber_count, context_id}, _from, state) do
    count =
      state.subscriptions
      |> Map.get(context_id, [])
      |> length()

    {:reply, count, state}
  end

  @impl true
  def handle_cast({:notify, entry}, state) do
    context_id = entry.context_id

    state.subscriptions
    |> Map.get(context_id, [])
    |> Enum.each(fn {pid, _ref, key_filter} ->
      if is_nil(key_filter) or entry.key == key_filter do
        send(pid, {:context_entry, entry})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      {context_id, pid} ->
        {new_subs, new_monitors} = remove_subscriber(state, context_id, pid)
        {:noreply, %{state | subscriptions: new_subs, monitors: new_monitors}}
    end
  end

  defp remove_subscriber(state, context_id, pid) do
    # Find and demonitor the subscription
    subs = Map.get(state.subscriptions, context_id, [])

    {removed, remaining} = Enum.split_with(subs, fn {p, _ref, _key} -> p == pid end)

    Enum.each(removed, fn {_pid, ref, _key} ->
      Process.demonitor(ref, [:flush])
    end)

    new_subs =
      if remaining == [] do
        Map.delete(state.subscriptions, context_id)
      else
        Map.put(state.subscriptions, context_id, remaining)
      end

    # Remove from monitors map
    refs_to_remove = Enum.map(removed, fn {_pid, ref, _key} -> ref end)
    new_monitors = Map.drop(state.monitors, refs_to_remove)

    {new_subs, new_monitors}
  end
end
