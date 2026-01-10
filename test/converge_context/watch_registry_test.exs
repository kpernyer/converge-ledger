defmodule ConvergeContext.WatchRegistryTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ConvergeContext.Entry
  alias ConvergeContext.WatchRegistry

  # Generators - use random bytes to ensure unique context IDs per check
  defp context_id_gen do
    StreamData.map(
      StreamData.binary(length: 8),
      fn bytes -> Base.encode16(bytes, case: :lower) end
    )
  end

  defp key_gen do
    StreamData.member_of(["facts", "intents", "traces", "evaluations"])
  end

  defp payload_gen do
    StreamData.binary(min_length: 1, max_length: 64)
  end

  # Unit Tests

  describe "subscribe/2" do
    test "returns ok with reference" do
      {:ok, ref} = WatchRegistry.subscribe("test-ctx")
      assert is_reference(ref)
    end

    test "can subscribe multiple times to same context" do
      {:ok, ref1} = WatchRegistry.subscribe("ctx")
      {:ok, ref2} = WatchRegistry.subscribe("ctx")

      assert ref1 != ref2
    end

    test "can subscribe to different contexts" do
      {:ok, ref1} = WatchRegistry.subscribe("ctx-1")
      {:ok, ref2} = WatchRegistry.subscribe("ctx-2")

      assert ref1 != ref2
    end

    test "can subscribe with key filter" do
      {:ok, ref} = WatchRegistry.subscribe("ctx", "facts")
      assert is_reference(ref)
    end
  end

  describe "unsubscribe/1" do
    test "removes subscription" do
      {:ok, _ref} = WatchRegistry.subscribe("ctx")
      assert WatchRegistry.subscriber_count("ctx") == 1

      :ok = WatchRegistry.unsubscribe("ctx")
      assert WatchRegistry.subscriber_count("ctx") == 0
    end

    test "only removes own subscription" do
      # Subscribe from main process
      {:ok, _} = WatchRegistry.subscribe("ctx")

      # Subscribe from another process
      task =
        Task.async(fn ->
          {:ok, _} = WatchRegistry.subscribe("ctx")
          # Keep process alive briefly
          Process.sleep(100)
        end)

      # Give time for subscription
      Process.sleep(10)
      assert WatchRegistry.subscriber_count("ctx") == 2

      # Unsubscribe main process
      :ok = WatchRegistry.unsubscribe("ctx")
      assert WatchRegistry.subscriber_count("ctx") == 1

      Task.await(task)
    end
  end

  describe "subscriber_count/1" do
    test "returns 0 for no subscribers" do
      assert WatchRegistry.subscriber_count("no-subs") == 0
    end

    test "correctly counts subscribers" do
      {:ok, _} = WatchRegistry.subscribe("ctx")
      assert WatchRegistry.subscriber_count("ctx") == 1

      {:ok, _} = WatchRegistry.subscribe("ctx")
      assert WatchRegistry.subscriber_count("ctx") == 2

      {:ok, _} = WatchRegistry.subscribe("ctx")
      assert WatchRegistry.subscriber_count("ctx") == 3
    end

    test "counts are independent per context" do
      {:ok, _} = WatchRegistry.subscribe("ctx-a")
      {:ok, _} = WatchRegistry.subscribe("ctx-a")
      {:ok, _} = WatchRegistry.subscribe("ctx-b")

      assert WatchRegistry.subscriber_count("ctx-a") == 2
      assert WatchRegistry.subscriber_count("ctx-b") == 1
      assert WatchRegistry.subscriber_count("ctx-c") == 0
    end
  end

  describe "notify/1" do
    test "sends entry to subscriber" do
      {:ok, _} = WatchRegistry.subscribe("ctx")

      entry = Entry.new("ctx", "facts", "payload", 1)
      WatchRegistry.notify(entry)

      assert_receive {:context_entry, received_entry}
      assert received_entry.id == entry.id
      assert received_entry.payload == entry.payload
    end

    test "sends to all subscribers of context" do
      # Main process subscribes
      {:ok, _} = WatchRegistry.subscribe("ctx")

      # Another process subscribes
      test_pid = self()

      task =
        Task.async(fn ->
          {:ok, _} = WatchRegistry.subscribe("ctx")
          send(test_pid, :subscribed)

          receive do
            {:context_entry, entry} -> send(test_pid, {:task_received, entry})
          after
            1000 -> send(test_pid, :timeout)
          end
        end)

      # Wait for task to subscribe
      assert_receive :subscribed

      entry = Entry.new("ctx", "facts", "payload", 1)
      WatchRegistry.notify(entry)

      # Main process receives
      assert_receive {:context_entry, _}

      # Task process receives
      assert_receive {:task_received, received}
      assert received.id == entry.id

      Task.await(task)
    end

    test "only sends to subscribers of matching context" do
      {:ok, _} = WatchRegistry.subscribe("ctx-a")

      entry = Entry.new("ctx-b", "facts", "payload", 1)
      WatchRegistry.notify(entry)

      refute_receive {:context_entry, _}, 100
    end

    test "respects key filter" do
      {:ok, _} = WatchRegistry.subscribe("ctx", "facts")

      # Should receive - matching key
      facts_entry = Entry.new("ctx", "facts", "payload", 1)
      WatchRegistry.notify(facts_entry)
      assert_receive {:context_entry, received}
      assert received.key == "facts"

      # Should NOT receive - different key
      intents_entry = Entry.new("ctx", "intents", "payload", 2)
      WatchRegistry.notify(intents_entry)
      refute_receive {:context_entry, _}, 100
    end

    test "nil key filter receives all keys" do
      {:ok, _} = WatchRegistry.subscribe("ctx", nil)

      entry1 = Entry.new("ctx", "facts", "p1", 1)
      entry2 = Entry.new("ctx", "intents", "p2", 2)

      WatchRegistry.notify(entry1)
      WatchRegistry.notify(entry2)

      assert_receive {:context_entry, %{key: "facts"}}
      assert_receive {:context_entry, %{key: "intents"}}
    end
  end

  describe "process cleanup" do
    test "cleans up when subscriber process exits normally" do
      task =
        Task.async(fn ->
          {:ok, _} = WatchRegistry.subscribe("ctx")
          :ok
        end)

      Task.await(task)

      # Give registry time to process DOWN message
      Process.sleep(50)

      assert WatchRegistry.subscriber_count("ctx") == 0
    end

    test "cleans up when subscriber process crashes" do
      {:ok, pid} =
        Task.start(fn ->
          {:ok, _} = WatchRegistry.subscribe("ctx")
          # Wait to be killed
          Process.sleep(:infinity)
        end)

      # Give time for subscription
      Process.sleep(10)
      assert WatchRegistry.subscriber_count("ctx") == 1

      # Kill the process
      Process.exit(pid, :kill)

      # Give registry time to process DOWN message
      Process.sleep(50)

      assert WatchRegistry.subscriber_count("ctx") == 0
    end
  end

  # Property Tests

  describe "property: subscription management" do
    property "subscriber count equals number of subscriptions from different processes" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(1..10)
            ) do
        # Subscribe from multiple processes
        tasks =
          for _ <- 1..count do
            Task.async(fn ->
              {:ok, _} = WatchRegistry.subscribe(context_id)
              # Stay alive
              receive do
                :done -> :ok
              end
            end)
          end

        # Give time for subscriptions
        Process.sleep(50)

        assert WatchRegistry.subscriber_count(context_id) == count

        # Cleanup
        for task <- tasks, do: send(task.pid, :done)
        for task <- tasks, do: Task.await(task)

        # After tasks exit, count should be 0
        Process.sleep(50)
        assert WatchRegistry.subscriber_count(context_id) == 0
      end
    end

    property "subscriptions from same process accumulate" do
      check all(
              context_id <- context_id_gen(),
              count <- StreamData.integer(1..5)
            ) do
        # Subscribe multiple times from single spawned process
        test_pid = self()

        task =
          Task.async(fn ->
            for _ <- 1..count, do: WatchRegistry.subscribe(context_id)
            send(test_pid, :subscribed)

            receive do
              :done -> :ok
            end
          end)

        assert_receive :subscribed

        # All subscriptions should be counted
        assert WatchRegistry.subscriber_count(context_id) == count

        # Cleanup
        send(task.pid, :done)
        Task.await(task)
      end
    end

    property "contexts are independent" do
      check all(
              contexts <-
                StreamData.list_of(context_id_gen(), min_length: 2, max_length: 5)
                |> StreamData.map(&Enum.uniq/1)
                |> StreamData.filter(&(length(&1) >= 2)),
              counts <- StreamData.list_of(StreamData.integer(1..5), min_length: 2, max_length: 5)
            ) do
        pairs = Enum.zip(contexts, counts)

        # Subscribe to each context the specified number of times
        for {ctx, count} <- pairs do
          for _ <- 1..count, do: WatchRegistry.subscribe(ctx)
        end

        # Verify each context has correct count
        for {ctx, count} <- pairs do
          assert WatchRegistry.subscriber_count(ctx) == count
        end

        # Cleanup
        for {ctx, count} <- pairs do
          for _ <- 1..count, do: WatchRegistry.unsubscribe(ctx)
        end
      end
    end
  end

  describe "property: notification delivery" do
    property "all subscribers receive notifications" do
      check all(
              context_id <- context_id_gen(),
              subscriber_count <- StreamData.integer(1..5),
              notification_count <- StreamData.integer(1..5)
            ) do
        test_pid = self()
        ref = make_ref()

        # Create subscriber processes
        subscribers =
          for i <- 1..subscriber_count do
            Task.async(fn ->
              {:ok, _} = WatchRegistry.subscribe(context_id)
              send(test_pid, {:subscribed, ref, i})

              # Collect notifications
              notifications =
                for _ <- 1..notification_count do
                  receive do
                    {:context_entry, entry} -> entry
                  after
                    1000 -> nil
                  end
                end

              send(test_pid, {:done, ref, i, notifications})
              :ok
            end)
          end

        # Wait for all subscriptions
        for i <- 1..subscriber_count do
          assert_receive {:subscribed, ^ref, ^i}
        end

        # Send notifications
        entries =
          for seq <- 1..notification_count do
            entry = Entry.new(context_id, "facts", "payload-#{seq}", seq)
            WatchRegistry.notify(entry)
            entry
          end

        # Collect results from all subscribers
        for i <- 1..subscriber_count do
          assert_receive {:done, ^ref, ^i, notifications}, 2000

          # Each subscriber should have received all notifications
          assert length(Enum.reject(notifications, &is_nil/1)) == notification_count

          # Payloads should match
          received_payloads = notifications |> Enum.reject(&is_nil/1) |> Enum.map(& &1.payload)
          expected_payloads = Enum.map(entries, & &1.payload)
          assert Enum.sort(received_payloads) == Enum.sort(expected_payloads)
        end

        # Cleanup
        for task <- subscribers, do: Task.await(task)
      end
    end

    property "key filter correctly filters notifications" do
      check all(
              context_id <- context_id_gen(),
              filter_key <- key_gen(),
              entries_spec <-
                StreamData.list_of(
                  StreamData.tuple({key_gen(), payload_gen()}),
                  min_length: 5,
                  max_length: 20
                )
            ) do
        test_pid = self()
        ref = make_ref()

        # Create subscriber with key filter
        task =
          Task.async(fn ->
            {:ok, _} = WatchRegistry.subscribe(context_id, filter_key)
            send(test_pid, {:subscribed, ref})

            # Collect notifications
            notifications = collect_notifications(length(entries_spec) * 2, 500)
            send(test_pid, {:done, ref, notifications})
            :ok
          end)

        assert_receive {:subscribed, ^ref}

        # Send entries with various keys
        entries =
          for {{key, payload}, seq} <- Enum.with_index(entries_spec, 1) do
            entry = Entry.new(context_id, key, payload, seq)
            WatchRegistry.notify(entry)
            entry
          end

        assert_receive {:done, ^ref, notifications}, 2000

        # All received notifications should have the filter key
        assert Enum.all?(notifications, &(&1.key == filter_key))

        # Count should match entries with that key
        expected_count = Enum.count(entries, &(&1.key == filter_key))
        assert length(notifications) == expected_count

        Task.await(task)
      end
    end
  end

  describe "property: subscription references are unique" do
    property "each subscription gets unique reference" do
      check all(count <- StreamData.integer(2..50)) do
        refs =
          for _ <- 1..count do
            {:ok, ref} = WatchRegistry.subscribe("ctx-#{:rand.uniform(1000)}")
            ref
          end

        assert length(refs) == length(Enum.uniq(refs))

        # Cleanup - unsubscribe all
        # (This is approximate since we subscribed from same process)
      end
    end
  end

  # Helper function to collect notifications with timeout
  defp collect_notifications(max_count, timeout_ms) do
    collect_notifications([], max_count, timeout_ms)
  end

  defp collect_notifications(acc, 0, _timeout_ms), do: Enum.reverse(acc)

  defp collect_notifications(acc, remaining, timeout_ms) do
    receive do
      {:context_entry, entry} ->
        collect_notifications([entry | acc], remaining - 1, timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end
