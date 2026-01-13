defmodule ConvergeLedger.Integrity.LamportClockTest do
  use ExUnit.Case, async: true

  alias ConvergeLedger.Integrity.LamportClock

  describe "new/0 and new/1" do
    test "creates clock initialized to 0" do
      clock = LamportClock.new()
      assert LamportClock.time(clock) == 0
    end

    test "creates clock with specific initial time" do
      clock = LamportClock.new(100)
      assert LamportClock.time(clock) == 100
    end
  end

  describe "tick/1 - local event ordering" do
    test "increments clock by 1" do
      clock = LamportClock.new()
      {clock, t1} = LamportClock.tick(clock)
      assert t1 == 1
      {clock, t2} = LamportClock.tick(clock)
      assert t2 == 2
      {_clock, t3} = LamportClock.tick(clock)
      assert t3 == 3
    end

    test "monotonically increasing" do
      clock = LamportClock.new()
      times =
        Enum.reduce(1..100, {clock, []}, fn _, {c, acc} ->
          {new_clock, time} = LamportClock.tick(c)
          {new_clock, [time | acc]}
        end)
        |> elem(1)
        |> Enum.reverse()

      assert times == Enum.to_list(1..100)
    end
  end

  describe "update/2 - receiving events from other nodes" do
    test "advances to max(local, received) + 1" do
      clock = LamportClock.new(5)
      {clock, time} = LamportClock.update(clock, 10)
      assert time == 11
      assert LamportClock.time(clock) == 11
    end

    test "when local is higher, uses local + 1" do
      clock = LamportClock.new(20)
      {clock, time} = LamportClock.update(clock, 10)
      assert time == 21
      assert LamportClock.time(clock) == 21
    end

    test "when times are equal, increments by 1" do
      clock = LamportClock.new(10)
      {clock, time} = LamportClock.update(clock, 10)
      assert time == 11
      assert LamportClock.time(clock) == 11
    end
  end

  describe "causal ordering - the key benefit" do
    test "local events are totally ordered" do
      # Simulating events on a single node
      clock = LamportClock.new()

      {events, _final_clock} =
        Enum.reduce([:create, :update, :read, :delete], {[], clock}, fn action, {acc, c} ->
          {new_clock, time} = LamportClock.tick(c)
          {[{action, time} | acc], new_clock}
        end)

      events = Enum.reverse(events)

      # All events have strictly increasing timestamps
      times = Enum.map(events, fn {_action, time} -> time end)
      assert times == [1, 2, 3, 4]

      # Can determine order: create < update < read < delete
      [{:create, t1}, {:update, t2}, {:read, t3}, {:delete, t4}] = events
      assert LamportClock.happened_before?(t1, t2)
      assert LamportClock.happened_before?(t2, t3)
      assert LamportClock.happened_before?(t3, t4)
    end

    test "cross-node causal ordering is preserved" do
      # Node A creates an entry
      node_a_clock = LamportClock.new()
      {_node_a_clock, create_time} = LamportClock.tick(node_a_clock)

      # Node B receives the entry and modifies it
      node_b_clock = LamportClock.new()
      # B updates its clock based on received timestamp
      {_node_b_clock, modify_time} = LamportClock.update(node_b_clock, create_time)

      # B's modification definitely happened after A's creation
      assert LamportClock.happened_before?(create_time, modify_time)
      assert modify_time > create_time
    end

    test "complex multi-node scenario preserves causality" do
      # Scenario: Node A creates, sends to B. B modifies, sends to C. C reads.
      #
      # A: create@1 --> B
      # B: receives@1, modify@2 --> C
      # C: receives@2, read@3

      # Node A creates entry
      node_a = LamportClock.new()
      {_node_a, a_create} = LamportClock.tick(node_a)
      assert a_create == 1

      # Node B receives from A and modifies
      node_b = LamportClock.new()
      {node_b, b_receive} = LamportClock.update(node_b, a_create)
      {_node_b, b_modify} = LamportClock.tick(node_b)
      assert b_receive == 2
      assert b_modify == 3

      # Node C receives from B and reads
      node_c = LamportClock.new()
      {node_c, c_receive} = LamportClock.update(node_c, b_modify)
      {_node_c, c_read} = LamportClock.tick(node_c)
      assert c_receive == 4
      assert c_read == 5

      # Causal chain is preserved
      assert LamportClock.happened_before?(a_create, b_receive)
      assert LamportClock.happened_before?(b_modify, c_receive)
      assert LamportClock.happened_before?(a_create, c_read)
    end

    test "concurrent events may have any ordering" do
      # Two nodes working independently without communication
      node_a = LamportClock.new()
      node_b = LamportClock.new()

      {_node_a, a_time} = LamportClock.tick(node_a)
      {_node_b, b_time} = LamportClock.tick(node_b)

      # Both have time 1 - they're concurrent (neither happened-before the other)
      assert a_time == 1
      assert b_time == 1
      assert LamportClock.compare(a_time, b_time) == :eq
    end
  end

  describe "merge/2 - combining state from multiple sources" do
    test "takes maximum of both clocks" do
      clock_a = LamportClock.new(10)
      clock_b = LamportClock.new(20)
      merged = LamportClock.merge(clock_a, clock_b)
      assert LamportClock.time(merged) == 20
    end

    test "is commutative" do
      clock_a = LamportClock.new(15)
      clock_b = LamportClock.new(25)
      merged_ab = LamportClock.merge(clock_a, clock_b)
      merged_ba = LamportClock.merge(clock_b, clock_a)
      assert LamportClock.time(merged_ab) == LamportClock.time(merged_ba)
    end

    test "is associative" do
      clock_a = LamportClock.new(5)
      clock_b = LamportClock.new(10)
      clock_c = LamportClock.new(15)

      merged_ab_c = LamportClock.merge(LamportClock.merge(clock_a, clock_b), clock_c)
      merged_a_bc = LamportClock.merge(clock_a, LamportClock.merge(clock_b, clock_c))

      assert LamportClock.time(merged_ab_c) == LamportClock.time(merged_a_bc)
    end
  end

  describe "compare/2" do
    test "returns :lt when first is smaller" do
      assert LamportClock.compare(1, 5) == :lt
    end

    test "returns :gt when first is larger" do
      assert LamportClock.compare(10, 3) == :gt
    end

    test "returns :eq when equal" do
      assert LamportClock.compare(7, 7) == :eq
    end
  end

  describe "happened_before?/2" do
    test "true when first timestamp is smaller" do
      assert LamportClock.happened_before?(1, 5) == true
    end

    test "false when first timestamp is larger" do
      assert LamportClock.happened_before?(10, 3) == false
    end

    test "false when timestamps are equal (concurrent)" do
      assert LamportClock.happened_before?(5, 5) == false
    end
  end

  describe "practical use case: entry ordering" do
    test "entries can be sorted by Lamport clock for consistent ordering" do
      # Simulate entries arriving out of order from different nodes
      entries = [
        %{id: "e1", lamport_clock: 5, payload: "first event"},
        %{id: "e2", lamport_clock: 2, payload: "earlier event"},
        %{id: "e3", lamport_clock: 8, payload: "later event"},
        %{id: "e4", lamport_clock: 1, payload: "earliest event"}
      ]

      sorted = Enum.sort_by(entries, & &1.lamport_clock)

      assert Enum.map(sorted, & &1.id) == ["e4", "e2", "e1", "e3"]
      assert Enum.map(sorted, & &1.payload) == [
        "earliest event",
        "earlier event",
        "first event",
        "later event"
      ]
    end

    test "wall clock times can lie, Lamport clocks cannot" do
      # Entry A created at wall time 10:00, Lamport 1
      # Entry B created at wall time 9:55 (clock skew!), but is causally after A, Lamport 2
      entry_a = %{wall_time: ~T[10:00:00], lamport: 1}
      entry_b = %{wall_time: ~T[09:55:00], lamport: 2}

      # Wall clock ordering is wrong (B appears before A)
      wall_sorted = Enum.sort_by([entry_a, entry_b], & &1.wall_time)
      assert hd(wall_sorted).lamport == 2  # Wrong! B is first

      # Lamport ordering is correct (A before B)
      lamport_sorted = Enum.sort_by([entry_a, entry_b], & &1.lamport)
      assert hd(lamport_sorted).lamport == 1  # Correct! A is first
    end
  end
end
