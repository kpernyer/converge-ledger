defmodule ConvergeLedger.Cluster.MnesiaManager do
  @moduledoc """
  Manages Mnesia clustering.

  When new nodes join the Erlang cluster, this GenServer ensures
  Mnesia connects to them and replicates the schema and tables.
  """

  use GenServer
  require Logger
  alias ConvergeLedger.Storage.Schema

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Monitor node up/down events
    :net_kernel.monitor_nodes(true)

    # Handle nodes that might already be connected
    Node.list()
    |> Enum.each(fn node ->
      Task.start(fn -> join_mnesia_cluster(node) end)
    end)

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node #{node} joined the cluster. Attempting to sync Mnesia.")
    
    Task.start(fn -> 
      join_mnesia_cluster(node)
    end)
    
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Node #{node} left the cluster.")
    {:noreply, state}
  end

  defp join_mnesia_cluster(node) do
    # 1. Connect Mnesia to the other node
    case :mnesia.change_config(:extra_db_nodes, [node]) do
      {:ok, _} ->
        Logger.info("Mnesia connected to #{node}")
        
        # 2. Ensure we have the schema copy
        # If we are a fresh node, we might want to copy schema from the other node.
        # But Mnesia is tricky. If we both have schemas, we might merge or fail.
        # For simplicity, we assume we want to replicate tables.
        
        replicate_tables()

      {:error, reason} ->
        Logger.error("Failed to connect Mnesia to #{node}: #{inspect(reason)}")
    end
  end

  defp replicate_tables do
    # For each table defined in Schema, ensure a copy exists on this node
    # and on other nodes if possible.
    
    # Actually, if we are using Mnesia, we typically want to add a copy 
    # of the table to the new node OR add a copy to ourselves if we are new.
    
    # Strategy: "I am running. I see a peer. I want to make sure I have a copy of the data."
    
    [Schema.entries_table(), Schema.sequences_table()]
    |> Enum.each(fn table ->
      ensure_table_copy(table)
    end)
  end

  defp ensure_table_copy(table) do
    # Check if we already have a copy
    case :mnesia.table_info(table, :storage_type) do
      :unknown ->
        # Table doesn't exist here? It should if Schema.init ran.
        # But if we are joining a cluster, maybe we want to pull data.
        add_table_copy(table)
      
      _type ->
        # We have it.
        :ok
    end
  end

  defp add_table_copy(table) do
    # We try to add a copy to the local node. 
    # If the table exists elsewhere, this triggers replication.
    case :mnesia.add_table_copy(table, node(), :ram_copies) do
      {:atomic, :ok} -> 
        Logger.info("Added local copy of #{table}")
      {:aborted, {:already_exists, _, _}} -> 
        :ok
      {:aborted, reason} ->
        Logger.error("Failed to add copy of #{table}: #{inspect(reason)}")
    end
  end
end
