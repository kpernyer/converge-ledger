defmodule ConvergeLedger.DiscoveryTest do
  use ExUnit.Case
  alias ConvergeLedger.Discovery

  test "processes can join and leave context groups" do
    context_id = "context-test-#{System.unique_integer()}"

    # Initially empty (or undefined)
    assert Discovery.members(context_id) == []

    # Join group
    Discovery.join(context_id)
    
    # Check membership
    members = Discovery.members(context_id)
    assert self() in members
    assert length(members) == 1

    # Another process joins
    task = Task.async(fn ->
      Discovery.join(context_id)
      Process.sleep(100) # Keep alive
    end)
    
    # Wait for propagation (pg is eventually consistent, but fast locally)
    Process.sleep(10)
    
    members = Discovery.members(context_id)
    assert length(members) == 2
    assert task.pid in members

    # Leave group
    Discovery.leave(context_id)
    members = Discovery.members(context_id)
    assert self() not in members
    assert length(members) == 1
  end
end
