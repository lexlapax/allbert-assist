defmodule AllbertAssist.Plugin.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Plugin.Bootstrap
  alias AllbertAssist.Plugin.ChildSupervisor
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry

  defmodule ValidPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.registry"

    @impl true
    def display_name, do: "Example Registry"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule DuplicatePlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.registry"

    @impl true
    def display_name, do: "Duplicate Registry"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule ChildPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.child"

    @impl true
    def display_name, do: "Example Child"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def child_spec(_opts) do
      %{
        id: {__MODULE__, :agent},
        start: {Agent, :start_link, [fn -> %{plugin: plugin_id()} end, []]}
      }
    end
  end

  defmodule IgnoreChildPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.ignore_child"

    @impl true
    def display_name, do: "Example Ignore Child"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule DuplicateChildPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.duplicate_child"

    @impl true
    def display_name, do: "Example Duplicate Child"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def child_spec(_opts) do
      %{
        id: {ChildPlugin, :agent},
        start: {Agent, :start_link, [fn -> %{plugin: plugin_id()} end, []]}
      }
    end
  end

  setup do
    registry = :"plugin_registry_#{System.unique_integer([:positive])}"
    table = :"plugin_registry_table_#{System.unique_integer([:positive])}"
    child_supervisor = :"plugin_child_supervisor_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, name: registry, table_name: table})
    start_supervised!({ChildSupervisor, name: child_supervisor})

    {:ok, registry: registry, child_supervisor: child_supervisor}
  end

  test "registers modules and returns entries in order", %{registry: registry} do
    assert {:ok, "example.registry"} = Registry.register_module(ValidPlugin, server: registry)

    assert [%{plugin_id: "example.registry"}] = Registry.registered_plugins(server: registry)
    assert {:ok, entry} = Registry.lookup("example.registry", server: registry)
    assert entry.module == ValidPlugin
    assert entry.source == :shipped
  end

  test "records duplicate plugin ids as diagnostics", %{registry: registry} do
    assert {:ok, "example.registry"} = Registry.register_module(ValidPlugin, server: registry)

    assert {:error, {:plugin_id_taken, "example.registry"}} =
             Registry.register_module(DuplicatePlugin, server: registry)

    diagnostics = Registry.diagnostics(server: registry)
    assert [%{kind: :duplicate_plugin_id}] = diagnostics["example.registry"]
  end

  test "clear removes entries and diagnostics", %{registry: registry} do
    assert {:ok, "example.registry"} = Registry.register_module(ValidPlugin, server: registry)
    Registry.put_diagnostics("example.registry", [%{kind: :test}], server: registry)

    assert :ok = Registry.clear(server: registry)
    assert [] = Registry.registered_plugins(server: registry)
    assert %{} = Registry.diagnostics(server: registry)
  end

  test "discovery finds shipped source-tree plugins" do
    discoveries =
      Discovery.discover(
        project_root: repo_root(),
        settings: %{
          "enabled" => [],
          "disabled" => [],
          "scan_paths" => ["./plugins"],
          "trusted_project_roots" => [],
          "load_policy" => "shipped_and_skill_only"
        }
      )

    assert {:module, AllbertAssist.Plugins.Telegram, _opts} =
             Enum.find(discoveries, &match?({:module, AllbertAssist.Plugins.Telegram, _}, &1))

    assert {:module, AllbertAssist.Plugins.Email, _opts} =
             Enum.find(discoveries, &match?({:module, AllbertAssist.Plugins.Email, _}, &1))

    assert {:module, AllbertBrowser.Plugin, _opts} =
             Enum.find(discoveries, &match?({:module, AllbertBrowser.Plugin, _}, &1))
  end

  test "discovery records missing, invalid, and disabled plugin diagnostics" do
    root = Path.join(System.tmp_dir!(), "plugin-discovery-#{System.unique_integer([:positive])}")
    plugins_root = Path.join(root, "plugins")
    invalid_root = Path.join(plugins_root, "invalid")
    disabled_root = Path.join(plugins_root, "disabled")
    missing_root = Path.join(root, "missing")

    File.mkdir_p!(invalid_root)
    File.mkdir_p!(disabled_root)

    File.write!(Path.join(invalid_root, "allbert_plugin.json"), "{")

    File.write!(Path.join(disabled_root, "allbert_plugin.json"), """
    {
      "schema_version": 1,
      "plugin_id": "example.disabled",
      "name": "Example Disabled",
      "version": "0.1.0",
      "kind": "skills",
      "skill_paths": []
    }
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    discoveries =
      Discovery.discover(
        project_root: root,
        settings: %{
          "enabled" => [],
          "disabled" => [],
          "scan_paths" => [missing_root, "./plugins"],
          "trusted_project_roots" => [],
          "load_policy" => "shipped_and_skill_only"
        }
      )

    assert {:diagnostic, ^missing_root, [%{kind: :plugin_scan_path_missing}]} =
             Enum.find(discoveries, &match?({:diagnostic, ^missing_root, _}, &1))

    assert {:diagnostic, ^invalid_root, [%{kind: :invalid_json}]} =
             Enum.find(discoveries, &match?({:diagnostic, ^invalid_root, _}, &1))

    assert {:diagnostic, "example.disabled", [%{kind: :plugin_not_enabled}]} =
             Enum.find(discoveries, &match?({:diagnostic, "example.disabled", _}, &1))
  end

  test "bootstrap registers discovered modules and starts plugin children", %{
    registry: registry,
    child_supervisor: child_supervisor
  } do
    start_supervised!(
      {Bootstrap,
       name: :"plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: registry,
       child_supervisor: child_supervisor,
       discoveries: [{:module, ChildPlugin, [source: :shipped]}]}
    )

    assert_eventually(fn ->
      assert [%{plugin_id: "example.child"}] = Registry.registered_plugins(server: registry)
      assert %{active: 1} = DynamicSupervisor.count_children(child_supervisor)
    end)

    assert [%{plugin_id: "example.child", child_spec: _spec}] =
             Registry.registered_child_specs(server: registry)
  end

  test "bootstrap accepts ignored children without starting a process", %{
    registry: registry,
    child_supervisor: child_supervisor
  } do
    start_supervised!(
      {Bootstrap,
       name: :"plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: registry,
       child_supervisor: child_supervisor,
       discoveries: [{:module, IgnoreChildPlugin, [source: :shipped]}]}
    )

    assert_eventually(fn ->
      assert [%{plugin_id: "example.ignore_child"}] =
               Registry.registered_plugins(server: registry)

      assert %{active: 0} = DynamicSupervisor.count_children(child_supervisor)
    end)

    assert [] = Registry.registered_child_specs(server: registry)
  end

  test "bootstrap records duplicate plugin child ids without starting another child", %{
    registry: registry,
    child_supervisor: child_supervisor
  } do
    start_supervised!(
      {Bootstrap,
       name: :"plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: registry,
       child_supervisor: child_supervisor,
       discoveries: [
         {:module, ChildPlugin, [source: :shipped]},
         {:module, DuplicateChildPlugin, [source: :shipped]}
       ]}
    )

    assert_eventually(fn ->
      assert %{active: 1} = DynamicSupervisor.count_children(child_supervisor)

      diagnostics = Registry.diagnostics(server: registry)
      assert [%{kind: :duplicate_child_id}] = diagnostics["example.duplicate_child"]
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      end
  end

  defp repo_root, do: Path.expand("../../../../../", __DIR__)
end
