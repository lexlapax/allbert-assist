defmodule AllbertAssist.App.SupervisorRestartTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry
  alias AllbertAssist.Conversations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Session
  alias AllbertAssist.TestSupport.ShippedRegistries

  defmodule ValidApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :restart_valid_app

    @impl true
    def display_name, do: "Restart Valid App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule BrokenApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :restart_broken_app

    @impl true
    def display_name, do: "Restart Broken App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts) do
      {:error, [%{kind: :restart_broken, message: "broken restart app", detail: %{safe: true}}]}
    end
  end

  defmodule PluginApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :plugin_bootstrap_app

    @impl true
    def display_name, do: "Plugin Bootstrap App"

    @impl true
    def version, do: "0.17.0"

    @impl true
    def validate(_opts), do: :ok
  end

  setup do
    original_apps = Application.get_env(:allbert_assist, :apps)
    original_bootstrap = Application.get_env(:allbert_assist, :apps_bootstrap)

    PluginRegistry.clear()
    PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    PluginRegistry.register_module(StockSage.Plugin)

    on_exit(fn ->
      ShippedRegistries.restore!()
      restore_env(:apps, original_apps)
      restore_env(:apps_bootstrap, original_bootstrap)
    end)

    :ok
  end

  test "one_for_all restart recreates the volatile registry and bootstraps configured apps" do
    registry = :"restart_registry_#{System.unique_integer([:positive])}"
    dynamic_supervisor = :"restart_dynamic_supervisor_#{System.unique_integer([:positive])}"
    bootstrap = :"restart_bootstrap_#{System.unique_integer([:positive])}"
    supervisor = :"restart_supervisor_#{System.unique_integer([:positive])}"
    table = :"restart_table_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {AllbertAssist.App.Supervisor,
         name: supervisor,
         registry: registry,
         dynamic_supervisor: dynamic_supervisor,
         bootstrap: bootstrap,
         table_name: table},
        id: supervisor
      )
    )

    assert wait_until(fn -> app_ids(registry) == [:allbert, :stocksage] end)

    old_pid = Process.whereis(registry)
    assert is_pid(old_pid)

    Process.exit(old_pid, :kill)

    assert wait_until(fn ->
             new_pid = Process.whereis(registry)

             is_pid(new_pid) and new_pid != old_pid and
               app_ids(registry) == [:allbert, :stocksage]
           end)
  end

  test "bootstrap failure records diagnostics while serving successful apps" do
    Application.put_env(:allbert_assist, :apps, [ValidApp, BrokenApp])

    registry = :"failure_registry_#{System.unique_integer([:positive])}"
    dynamic_supervisor = :"failure_dynamic_supervisor_#{System.unique_integer([:positive])}"
    bootstrap = :"failure_bootstrap_#{System.unique_integer([:positive])}"
    supervisor = :"failure_supervisor_#{System.unique_integer([:positive])}"
    table = :"failure_table_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {AllbertAssist.App.Supervisor,
         name: supervisor,
         registry: registry,
         dynamic_supervisor: dynamic_supervisor,
         bootstrap: bootstrap,
         table_name: table},
        id: supervisor
      )
    )

    assert wait_until(fn -> app_ids(registry) == [:restart_valid_app, :stocksage] end)

    assert {:ok, %{display_name: "Restart Valid App"}} =
             Registry.lookup(:restart_valid_app, server: registry)

    assert {:ok, %{display_name: "StockSage"}} = Registry.lookup(:stocksage, server: registry)

    assert {:error, :not_found} = Registry.lookup(:restart_broken_app, server: registry)

    assert %{restart_broken_app: [%{kind: :restart_broken}]} =
             Registry.diagnostics(server: registry)
  end

  test "app bootstrap consumes plugin-contributed apps" do
    PluginRegistry.clear()

    assert {:ok, "example.app"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.app",
               display_name: "Example App",
               version: "0.1.0",
               kind: "app",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               apps: [PluginApp]
             })

    registry = :"plugin_app_registry_#{System.unique_integer([:positive])}"
    dynamic_supervisor = :"plugin_app_dynamic_supervisor_#{System.unique_integer([:positive])}"
    bootstrap = :"plugin_app_bootstrap_#{System.unique_integer([:positive])}"
    supervisor = :"plugin_app_supervisor_#{System.unique_integer([:positive])}"
    table = :"plugin_app_table_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {AllbertAssist.App.Supervisor,
         name: supervisor,
         registry: registry,
         dynamic_supervisor: dynamic_supervisor,
         bootstrap: bootstrap,
         table_name: table},
        id: supervisor
      )
    )

    assert wait_until(fn -> :plugin_bootstrap_app in app_ids(registry) end)

    assert {:ok, %{display_name: "Plugin Bootstrap App"}} =
             Registry.lookup(:plugin_bootstrap_app, server: registry)
  end

  test "bootstrap can be disabled for tests without registering default apps" do
    Application.put_env(:allbert_assist, :apps_bootstrap, false)

    registry = :"disabled_bootstrap_registry_#{System.unique_integer([:positive])}"

    dynamic_supervisor =
      :"disabled_bootstrap_dynamic_supervisor_#{System.unique_integer([:positive])}"

    bootstrap = :"disabled_bootstrap_bootstrap_#{System.unique_integer([:positive])}"
    supervisor = :"disabled_bootstrap_supervisor_#{System.unique_integer([:positive])}"
    table = :"disabled_bootstrap_table_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {AllbertAssist.App.Supervisor,
         name: supervisor,
         registry: registry,
         dynamic_supervisor: dynamic_supervisor,
         bootstrap: bootstrap,
         table_name: table},
        id: supervisor
      )
    )

    assert Registry.registered_apps(server: registry) == []
    assert Registry.diagnostics(server: registry) == %{}
  end

  test "default registry restart preserves app validation and creates no durable rows" do
    user = "registry-restart-#{System.unique_integer([:positive])}"

    assert Conversations.list_threads(user) == []
    assert Jobs.list_jobs(user) == []
    assert {:ok, []} = Session.list(user)

    old_pid = Process.whereis(Registry)
    assert is_pid(old_pid)

    Process.exit(old_pid, :kill)

    assert wait_until(fn ->
             new_pid = Process.whereis(Registry)
             is_pid(new_pid) and new_pid != old_pid and :stocksage in app_ids(Registry)
           end)

    assert Conversations.list_threads(user) == []
    assert Jobs.list_jobs(user) == []
    assert {:ok, []} = Session.list(user)

    assert {:ok, response} =
             Runner.run(
               "set_active_app",
               %{user_id: user, session_id: "sess-1", app_id: "stocksage"},
               context(user)
             )

    assert response.status == :completed
    assert response.session.active_app == :stocksage

    on_exit(fn -> Session.clear(user, "sess-1") end)
  end

  defp app_ids(registry) do
    registry
    |> then(&Registry.registered_apps(server: &1))
    |> Enum.map(& &1.app_id)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp context(user) do
    %{request: %{input_signal_id: "input-sig", operator_id: user, user_id: user}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
