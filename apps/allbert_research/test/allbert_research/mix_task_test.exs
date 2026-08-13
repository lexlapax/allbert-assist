defmodule Mix.Tasks.Allbert.ResearchTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Store.Agent, as: ConfirmationStoreAgent
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertBrowser.Session
  alias AllbertResearch.DelegateObjective
  alias Mix.Tasks.Allbert.Research, as: ResearchTask

  defmodule StableReadiness do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def init(:ok) do
      barrier = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{barrier: barrier}}
    end

    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          phase: :ready,
          barrier_pid: state.barrier,
          snapshot_digest: String.duplicate("a", 64),
          expected_ids: [],
          subscribed_ids: [],
          acked_ids: [],
          diagnostics: []
        }}, state}
    end

    def terminate(_reason, state), do: Process.exit(state.barrier, :kill)
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)
    previous_halt = Application.get_env(:allbert_assist, ResearchTask)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-research-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)
    registry_owners = start_private_registries!()
    objective_engine = start_private_engine!()

    Application.put_env(:allbert_assist, ResearchTask,
      halt_fun: fn code -> throw({:halt, code}) end,
      registry_owners: registry_owners,
      objective_engine: objective_engine
    )

    ensure_browser_supervisor()
    ensure_research_supervisor()
    ensure_confirmation_store()
    close_all_sessions()
    replace_readiness!()

    assert {:ok, _setting} =
             Settings.put(
               "browser.enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "research.enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    Mix.Task.reenable("allbert.research")

    on_exit(fn ->
      close_all_sessions()
      Mix.Task.reenable("allbert.research")
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)

      if previous_halt do
        Application.put_env(:allbert_assist, ResearchTask, previous_halt)
      else
        Application.delete_env(:allbert_assist, ResearchTask)
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "runs grant-backed delegated URL research from the CLI" do
    remember_navigation_grant!("https://example.com/docs/")

    output =
      capture_io(fn ->
        ResearchTask.run(["https://example.com/docs/a", "--max-sources=1"])
      end)

    assert output =~ "Allbert research research.specialist"
    assert output =~ "Command: summarize_url"
    assert output =~ "Status: completed"
    assert output =~ "Summary: Research summary from 1 source"
    assert output =~ "Source: https://example.com/docs/a"

    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})

    assert [%{status: "completed", source_intent: "mix allbert.research"}] =
             Objectives.list_objectives("local", status: "completed", limit: 1)
  end

  test "ungranted delegated URL research prints the pending navigation confirmation" do
    output =
      capture_io(fn ->
        ResearchTask.run(["https://example.com/docs/pending", "--max-sources=1"])
      end)

    assert output =~ "Allbert research research.specialist"
    assert output =~ "Command: summarize_url"
    assert output =~ "Status: needs_confirmation"
    assert output =~ "Confirmation: "
    assert output =~ "Research summarize_url is waiting for browser_navigate confirmation."

    assert [%{status: "blocked", source_intent: "mix allbert.research"}] =
             Objectives.list_objectives("local", status: "blocked", limit: 1)
  end

  test "delegate carrier accepts one epoch amid options and rejects duplicate or malformed" do
    assert {:ok, epoch} = EffectGuard.admit_ready()

    assert {:error, :product_not_ready} =
             DelegateObjective.start("local", "https://example.com/docs/a",
               channel: :cli,
               trace_prefix: "duplicate",
               allbert_pack_epoch: epoch,
               allbert_pack_epoch: epoch
             )

    assert {:error, :product_not_ready} =
             DelegateObjective.start("local", "https://example.com/docs/a",
               channel: :cli,
               trace_prefix: "malformed",
               allbert_pack_epoch: Map.put(epoch, :unexpected, true)
             )

    assert Objectives.list_objectives("local", limit: 10) == []
  end

  defp remember_navigation_grant!(url) do
    {:ok, resource_uri} = ResourceURI.url(url, :prefix)

    {:ok, ref} =
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :remote_url,
        operation_class: :browser_navigate,
        access_mode: :fetch,
        scope: Scope.url_prefix(resource_uri),
        downstream_consumer: :browser_navigator
      })

    assert {:ok, _grant} = Grants.remember(ref, ReadyEffectContext.attach(%{audit?: false}))
  end

  defp ensure_browser_supervisor do
    unless Process.whereis(AllbertBrowser.Supervisor) do
      start_supervised!(AllbertBrowser.Supervisor)
    end
  end

  defp ensure_research_supervisor do
    if Process.whereis(AllbertResearch.Supervisor) do
      AllbertResearch.Runtime.register_if_available(AllbertResearch.Agent, AllbertResearch.Agent)
    else
      start_supervised!(AllbertResearch.Supervisor)
    end
  end

  defp ensure_confirmation_store do
    unless Process.whereis(ConfirmationStoreAgent) do
      start_supervised!(ConfirmationStoreAgent)
    end
  end

  defp close_all_sessions do
    Enum.each(Session.list(), fn %{session_id: session_id} ->
      Session.close(session_id)
    end)
  rescue
    ArgumentError -> :ok
  end

  defp start_private_registries! do
    suffix = System.unique_integer([:positive])
    plugin_owner = String.to_atom("research_test_plugin_registry_#{suffix}")
    plugin_table = String.to_atom("research_test_plugin_table_#{suffix}")
    app_owner = String.to_atom("research_test_app_registry_#{suffix}")
    app_table = String.to_atom("research_test_app_table_#{suffix}")

    start_supervised!({PluginRegistry, name: plugin_owner, table_name: plugin_table})
    start_supervised!({AppRegistry, name: app_owner, table_name: app_table})

    assert {:ok, "allbert.browser"} =
             PluginRegistry.register_module(AllbertBrowser.Plugin, server: plugin_owner)

    assert {:ok, "allbert.research"} =
             PluginRegistry.register_module(AllbertResearch.Plugin, server: plugin_owner)

    assert {:ok, :allbert} =
             AppRegistry.register(AllbertAssist.App.CoreApp, server: app_owner)

    assert {:ok, :allbert_research} =
             AppRegistry.register(AllbertResearch.App, server: app_owner)

    %{plugin: plugin_owner, app: app_owner}
  end

  defp start_private_engine! do
    name = String.to_atom("research_test_engine_#{System.unique_integer([:positive])}")
    start_supervised!({EngineAgent, name: name, id: Atom.to_string(name), child_id: name})
    name
  end

  defp replace_readiness! do
    original = Process.whereis(AllbertAssist.Pack.Readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)
    {:ok, replacement} = StableReadiness.start_link(name: AllbertAssist.Pack.Readiness)

    on_exit(fn ->
      if Process.whereis(AllbertAssist.Pack.Readiness) == replacement,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(replacement), do: GenServer.stop(replacement)

      if Process.alive?(original) and is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
        do: Process.register(original, AllbertAssist.Pack.Readiness)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
end
