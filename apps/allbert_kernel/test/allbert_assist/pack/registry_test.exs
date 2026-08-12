defmodule AllbertAssist.Pack.RegistryTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.Registry
  alias AllbertAssist.Pack.Registry.{Candidate, Snapshot}
  alias AllbertAssist.Pack.{ActionBinding, Compatibility, Contribution, Order}
  alias AllbertAssist.Pack.{PathSegment, ValidationDiagnostic}

  defmodule SlowServer do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :ok}

    def handle_call(:status, _from, state) do
      Process.sleep(5_100)
      {:reply, {:ok, :slow_status}, state}
    end
  end

  defmodule RaisingVia do
    def whereis_name(_term), do: raise("lookup failed")
  end

  defmodule RaisingFullVia do
    def whereis_name(_term), do: raise("lookup failed")
    def register_name(_term, _pid), do: :yes
    def unregister_name(_term), do: :ok
    def send(_term, _message), do: raise("send failed")
  end

  test "a private shadow registry starts collecting without a published snapshot" do
    registry = start_private_registry(coordinator: self())

    assert {:ok,
            %{
              phase: :collecting,
              publication: :shadow,
              behavior_digest: nil
            }} = Registry.status(server: registry)

    assert {:error, :collecting} = Registry.snapshot(server: registry)
    assert {:ok, []} = Registry.diagnostics(server: registry)
  end

  test "the coordinator atomically finalizes one complete candidate" do
    registry = start_private_registry(coordinator: self())

    candidate = %Candidate{
      schema_version: 1,
      contributions: [],
      action_bindings: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }

    expected_bytes =
      ~s({"compatibility_aliases":[],"compatibility_diagnostics":[],"contributions":[],"effective_actions":[],"schema_version":1})

    expected_digest =
      :crypto.hash(:sha256, "allbert.pack.snapshot.v1\0" <> expected_bytes)
      |> Base.encode16(case: :lower)

    assert {:ok,
            %Snapshot{
              schema_version: 1,
              publication: :shadow,
              behavior_digest: ^expected_digest,
              contributions: [],
              effective_actions: [],
              compatibility_aliases: [],
              compatibility_diagnostics: []
            } = snapshot} = Registry.finalize(candidate, server: registry)

    assert {:ok, %{phase: :finalized, publication: :shadow, behavior_digest: ^expected_digest}} =
             Registry.status(server: registry)

    assert {:ok, ^snapshot} = Registry.snapshot(server: registry)
    assert {:ok, []} = Registry.diagnostics(server: registry)
  end

  test "M1.b starts an explicitly authoritative collecting registry" do
    name = :m1b_authoritative_registry

    assert {:ok, pid} =
             Registry.start_link(
               name: name,
               publication: :authoritative,
               coordinator: self()
             )

    assert Process.whereis(name) == pid

    assert {:ok, %{phase: :collecting, publication: :authoritative, behavior_digest: nil}} =
             Registry.status(server: name)
  end

  test "identical canonical finalization is idempotent" do
    registry = start_private_registry(coordinator: self())

    first = empty_candidate()
    second = empty_candidate()

    assert {:ok, snapshot} = Registry.finalize(first, server: registry)
    assert {:ok, ^snapshot} = Registry.finalize(second, server: registry)
    assert {:ok, ^snapshot} = Registry.snapshot(server: registry)
  end

  test "public calls use the bounded Pack finalization timeout, not GenServer's five-second default" do
    slow_server = start_supervised!(SlowServer)
    assert {:ok, :slow_status} = Registry.status(server: slow_server)
  end

  test "start options reject malformed, duplicate, unknown, and unsafe coordinator values" do
    assert {:error, {:invalid_options, :not_keyword}} = Registry.start_link(:bad)

    assert {:error, {:invalid_options, {:duplicate, :coordinator}}} =
             Registry.start_link(coordinator: self(), coordinator: self())

    assert {:error, {:invalid_options, {:unknown, :other}}} =
             Registry.start_link(other: true)

    assert {:error, {:invalid_options, {:invalid, :coordinator}}} =
             Registry.start_link(coordinator: "bad")

    assert {:error, {:invalid_options, {:invalid, :coordinator}}} =
             Registry.start_link(coordinator: {:via, String, :bad})

    assert {:error, {:invalid_options, {:invalid, :name}}} =
             Registry.start_link(name: self())
  end

  test "name nil starts an explicitly unregistered registry" do
    assert {:ok, pid} = Registry.start_link(name: nil, coordinator: self())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, %{phase: :collecting, publication: :shadow}} = Registry.status(server: pid)
  end

  test "a coordinator registry lookup failure denies finalization without killing Registry" do
    registry = start_private_registry(coordinator: {:via, RaisingVia, :coordinator})

    assert {:error, {:not_coordinator, %ValidationDiagnostic{code: :not_coordinator}}} =
             Registry.finalize(empty_candidate(), server: registry)

    assert {:ok, %{phase: :collecting}} = Registry.status(server: registry)
    assert Process.alive?(registry)
  end

  test "a malformed nested candidate cannot crash the registry" do
    registry = start_private_registry(coordinator: self())

    malformed = %Contribution{
      schema_version: 1,
      owner: nil,
      implementation_module: __MODULE__,
      descriptor: nil,
      source_lane: :legacy_plugin,
      owner_order: %Order{schema_version: 1, namespace: :legacy_plugin, value: 1},
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :legacy_plugin,
        legacy_id: "bad",
        alias_of: nil,
        trust: :pending,
        enabled: true
      },
      callbacks: %{}
    }

    candidate = %{empty_candidate() | contributions: [malformed]}

    assert {:error, {:invalid_candidate, [%ValidationDiagnostic{}]}} =
             Registry.finalize(candidate, server: registry)

    assert {:ok, %{phase: :collecting, behavior_digest: nil}} = Registry.status(server: registry)
    assert Process.alive?(registry)
  end

  test "invalid action capability diagnostics stay typed and leave Registry collecting" do
    registry = start_private_registry(coordinator: self())

    binding = %ActionBinding{
      schema_version: 1,
      module: __MODULE__,
      name: "invalid_capability",
      source_lane: :legacy_plugin,
      legacy_index: 1,
      registry_order: nil,
      normalized_capability: %{
        app_id: nil,
        confirmation: :always,
        execution_mode: :sync,
        exposure: :agent,
        notes: nil,
        permission: :execute,
        plugin_id: "plugin_one",
        resumable?: :yes,
        retry_safety: :safe,
        skill_backed?: true
      },
      m0_row_sha256: String.duplicate("a", 64),
      input_schema_sha256: String.duplicate("b", 64),
      output_schema_sha256: String.duplicate("c", 64)
    }

    candidate = %{empty_candidate() | action_bindings: [binding]}

    assert {:error,
            {:invalid_candidate,
             [
               %ValidationDiagnostic{
                 schema_version: 1,
                 code: :invalid_type,
                 path: [
                   %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                   %PathSegment{
                     schema_version: 1,
                     kind: :identity,
                     value: "invalid_capability"
                   },
                   %PathSegment{
                     schema_version: 1,
                     kind: :field,
                     value: "normalized_capability"
                   },
                   %PathSegment{schema_version: 1, kind: :field, value: "resumable?"}
                 ],
                 owner: nil,
                 detail: %{expected: "boolean", actual: "atom"}
               }
             ]}} = Registry.finalize(candidate, server: registry)

    assert {:ok, %{phase: :collecting, behavior_digest: nil}} = Registry.status(server: registry)
    assert Process.alive?(registry)
  end

  test "only the identified coordinator may finalize and denial is not persisted" do
    registry = start_private_registry(coordinator: self())

    result =
      Task.async(fn -> Registry.finalize(empty_candidate(), server: registry) end) |> Task.await()

    assert {:error,
            {:not_coordinator,
             %ValidationDiagnostic{
               schema_version: 1,
               code: :not_coordinator,
               path: [],
               owner: nil,
               detail: %{
                 expected: :registered_coordinator,
                 actual: :different_process
               }
             }}} = result

    assert {:ok, %{phase: :collecting, behavior_digest: nil}} = Registry.status(server: registry)
    assert {:ok, []} = Registry.diagnostics(server: registry)
  end

  test "invalid candidate diagnostics are typed and do not change collecting state" do
    registry = start_private_registry(coordinator: self())

    candidate = Map.put(empty_candidate(), :unexpected, true)

    assert {:error,
            {:invalid_candidate,
             [
               %ValidationDiagnostic{
                 schema_version: 1,
                 code: :unknown_field,
                 path: [
                   %PathSegment{
                     schema_version: 1,
                     kind: :field,
                     value: "unexpected"
                   }
                 ],
                 owner: nil,
                 detail: %{field: "unexpected"}
               }
             ]}} = Registry.finalize(candidate, server: registry)

    assert {:ok, %{phase: :collecting, behavior_digest: nil}} = Registry.status(server: registry)
    assert {:error, :collecting} = Registry.snapshot(server: registry)
    assert {:ok, []} = Registry.diagnostics(server: registry)
  end

  test "a restarted private registry returns to collecting without retained authority" do
    name = :m1a2_registry_restart_test

    assert {:ok, first_pid} =
             Registry.start_link(name: name, coordinator: self())

    assert {:ok, first_snapshot} = Registry.finalize(empty_candidate(), server: name)
    assert {:ok, ^first_snapshot} = Registry.snapshot(server: name)
    :ok = GenServer.stop(first_pid)

    assert {:ok, second_pid} =
             Registry.start_link(name: name, coordinator: self())

    on_exit(fn ->
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
    end)

    assert second_pid != first_pid

    assert {:ok, %{phase: :collecting, publication: :shadow, behavior_digest: nil}} =
             Registry.status(server: name)

    assert {:error, :collecting} = Registry.snapshot(server: name)
    assert {:ok, []} = Registry.diagnostics(server: name)
  end

  test "post-start calls normalize an unavailable private server" do
    server = :m1a2_registry_that_is_not_running

    assert {:error, :unavailable} = Registry.status(server: server)
    assert {:error, :unavailable} = Registry.snapshot(server: server)
    assert {:error, :unavailable} = Registry.finalize(empty_candidate(), server: server)
    assert {:error, :unavailable} = Registry.diagnostics(server: server)

    raising = {:via, RaisingFullVia, :bad}
    assert {:error, :unavailable} = Registry.status(server: raising)
  end

  test "the registry exports no incremental authority mutation API" do
    exports = Registry.__info__(:functions)

    for function <- [:register, :put, :reset, :clear] do
      refute Enum.any?(exports, fn {exported, _arity} -> exported == function end)
    end
  end

  defp empty_candidate do
    %Candidate{
      schema_version: 1,
      contributions: [],
      action_bindings: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }
  end

  defp start_private_registry(opts) do
    start_supervised!({Registry, Keyword.put_new(opts, :name, nil)})
  end
end
