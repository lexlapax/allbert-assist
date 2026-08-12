defmodule AllbertAssist.Plugin.SupervisorRestartTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Plugin.Bootstrap
  alias AllbertAssist.Plugin.Registry

  defmodule MetadataPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.metadata_restart"

    @impl true
    def display_name, do: "Example Metadata Restart"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok
  end

  test "metadata registry loss restarts the Registry/Bootstrap pair without starting a child supervisor" do
    registry = unique_name(:plugin_metadata_registry)
    bootstrap = unique_name(:plugin_metadata_bootstrap)
    supervisor = unique_name(:plugin_metadata_supervisor)
    table = unique_name(:plugin_metadata_table)

    start_supervised!(
      Supervisor.child_spec(
        {AllbertAssist.Plugin.Supervisor,
         name: supervisor,
         bootstrap: bootstrap,
         registry_opts: [name: registry, table_name: table],
         discoveries: [{:module, MetadataPlugin, [source: :shipped]}]},
        id: supervisor
      )
    )

    assert [{AllbertAssist.Plugin.MetadataSupervisor, _metadata_pid, :supervisor, _modules}] =
             Supervisor.which_children(supervisor)

    assert_eventually(fn ->
      assert [%{plugin_id: "example.metadata_restart"}] =
               Registry.registered_plugins(server: registry)
    end)

    old_registry = Process.whereis(registry)
    old_bootstrap = Process.whereis(bootstrap)
    assert is_pid(old_registry)
    assert is_pid(old_bootstrap)

    Process.exit(old_registry, :kill)

    assert_eventually(fn ->
      replacement_registry = Process.whereis(registry)
      replacement_bootstrap = Process.whereis(bootstrap)

      assert is_pid(replacement_registry) and replacement_registry != old_registry
      assert is_pid(replacement_bootstrap) and replacement_bootstrap != old_bootstrap

      assert [%{plugin_id: "example.metadata_restart"}] =
               Registry.registered_plugins(server: registry)
    end)
  end

  test "bootstrap completion evidence identifies one completed bootstrap process" do
    bootstrap = unique_name(:plugin_completion_bootstrap)
    bootstrap_pid = start_supervised!({Bootstrap, name: bootstrap, bootstrap?: false})

    assert {:ok, %{pid: ^bootstrap_pid, generation: 1, completion_token: completion_token}} =
             Bootstrap.completion_token(bootstrap)

    assert is_reference(completion_token)
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp assert_eventually(fun, attempts \\ 30)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end
end
