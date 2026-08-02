defmodule AllbertAssist.Objectives.Fanout.EndpointAdmissionTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Objectives.Fanout.EndpointAdmission

  @registry AllbertAssist.Objectives.Runs.Registry

  setup do
    endpoint = "http://127.0.0.1:11434/#{System.unique_integer([:positive])}"
    on_exit(fn -> Registry.unregister(@registry, EndpointAdmission.key(endpoint)) end)
    {:ok, endpoint: endpoint}
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  describe "endpoint identity" do
    test "resolves a local endpoint from either key shape" do
      assert EndpointAdmission.endpoint_id(%{
               "endpoint_kind" => "local_endpoint",
               "effective_endpoint" => "http://127.0.0.1:11434"
             }) == "http://127.0.0.1:11434"

      assert EndpointAdmission.endpoint_id(%{
               endpoint_kind: "local",
               configured_endpoint: "http://localhost:11434"
             }) == "http://localhost:11434"
    end

    test "prefers the effective endpoint over the configured one" do
      assert EndpointAdmission.endpoint_id(%{
               "endpoint_kind" => "local_endpoint",
               "configured_endpoint" => "http://configured:11434",
               "effective_endpoint" => "http://effective:11434"
             }) == "http://effective:11434"
    end

    test "returns nil for hosted, blank, unresolved, and non-map bindings" do
      for binding <- [
            %{"endpoint_kind" => "hosted", "effective_endpoint" => "https://api.example"},
            %{"endpoint_kind" => "local_endpoint", "effective_endpoint" => ""},
            %{"endpoint_kind" => "local_endpoint"},
            %{},
            nil,
            "http://127.0.0.1:11434"
          ] do
        assert EndpointAdmission.endpoint_id(binding) == nil, inspect(binding)
      end
    end
  end

  describe "admission" do
    test "a nil endpoint runs immediately and never serializes" do
      parent = self()

      tasks =
        for index <- 1..4 do
          Task.async(fn ->
            EndpointAdmission.with_endpoint(nil, deadline(5_000), fn ->
              send(parent, {:entered, index})
              # Every task holds the section at once; a serialization point here
              # would deadlock this barrier instead of returning.
              assert_receive :release, 2_000
              index
            end)
          end)
        end

      for index <- 1..4, do: assert_receive({:entered, ^index}, 2_000)
      for task <- tasks, do: send(task.pid, :release)

      assert tasks |> Task.await_many(5_000) |> Enum.sort() == [1, 2, 3, 4]
    end

    test "admits one in-flight call per local endpoint", %{endpoint: endpoint} do
      parent = self()
      holder_deadline = deadline(5_000)

      holder =
        Task.async(fn ->
          EndpointAdmission.with_endpoint(endpoint, holder_deadline, fn ->
            send(parent, :held)
            assert_receive :release, 2_000
            :first
          end)
        end)

      assert_receive :held, 2_000

      waiter =
        Task.async(fn ->
          EndpointAdmission.with_endpoint(endpoint, deadline(5_000), fn ->
            send(parent, :admitted)
            :second
          end)
        end)

      refute_receive :admitted, 300

      send(holder.pid, :release)
      assert Task.await(holder, 5_000) == :first
      assert Task.await(waiter, 5_000) == :second
      assert_received :admitted
    end

    test "different endpoints do not serialize against each other", %{endpoint: endpoint} do
      parent = self()
      other = endpoint <> "-other"
      on_exit(fn -> Registry.unregister(@registry, EndpointAdmission.key(other)) end)

      tasks =
        for {id, name} <- [{endpoint, :a}, {other, :b}] do
          Task.async(fn ->
            EndpointAdmission.with_endpoint(id, deadline(5_000), fn ->
              send(parent, {:entered, name})
              assert_receive :release, 2_000
              name
            end)
          end)
        end

      assert_receive {:entered, :a}, 2_000
      assert_receive {:entered, :b}, 2_000

      for task <- tasks, do: send(task.pid, :release)
      assert tasks |> Task.await_many(5_000) |> Enum.sort() == [:a, :b]
    end

    test "waiting past the plan deadline fails closed without running the call", %{
      endpoint: endpoint
    } do
      parent = self()

      holder =
        Task.async(fn ->
          EndpointAdmission.with_endpoint(endpoint, deadline(5_000), fn ->
            send(parent, :held)
            assert_receive :release, 2_000
            :first
          end)
        end)

      assert_receive :held, 2_000

      assert EndpointAdmission.with_endpoint(endpoint, deadline(50), fn ->
               send(parent, :must_not_run)
               :second
             end) == {:error, :fanout_plan_deadline_exhausted}

      refute_received :must_not_run

      send(holder.pid, :release)
      assert Task.await(holder, 5_000) == :first
    end

    test "a raising call releases admission for the next child", %{endpoint: endpoint} do
      assert_raise RuntimeError, "child failed", fn ->
        EndpointAdmission.with_endpoint(endpoint, deadline(5_000), fn ->
          raise "child failed"
        end)
      end

      assert EndpointAdmission.with_endpoint(endpoint, deadline(1_000), fn -> :admitted end) ==
               :admitted
    end

    test "an errored call still releases admission", %{endpoint: endpoint} do
      assert EndpointAdmission.with_endpoint(endpoint, deadline(5_000), fn ->
               {:error, :provider_unavailable}
             end) == {:error, :provider_unavailable}

      assert EndpointAdmission.with_endpoint(endpoint, deadline(1_000), fn -> :admitted end) ==
               :admitted
    end

    test "a killed holder releases admission for the next child", %{endpoint: endpoint} do
      parent = self()

      holder =
        spawn(fn ->
          EndpointAdmission.with_endpoint(endpoint, deadline(30_000), fn ->
            send(parent, :held)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :held, 2_000
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 2_000

      assert EndpointAdmission.with_endpoint(endpoint, deadline(2_000), fn -> :admitted end) ==
               :admitted
    end
  end
end
