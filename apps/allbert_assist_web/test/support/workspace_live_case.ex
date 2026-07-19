defmodule AllbertAssistWeb.WorkspaceLiveCase do
  @moduledoc """
  Shared per-test environment and helpers for the workspace LiveView test
  files split out of `workspace_live_test.exs` (v1.0.2 M4).

  Each split file still declares its own
  `use AllbertAssistWeb.ConnCase, async: false` first, so the lane comes from
  the ConnCase template default (`liveview_serial`) or an explicit `lane:`
  use-line override. This module only owns the common per-test environment
  (owned tmp home, fixture runtime runner, session reset with full env
  restore) and the helpers more than one split file needs.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.LiveViewTest, only: [has_element?: 2, render: 1]

  alias AllbertAssist.{Channels, Confirmations, Conversations, Paths, Runtime, Session, Settings}
  alias Jido.Signal.Bus

  defmacro __using__(_opts) do
    quote do
      import AllbertAssistWeb.WorkspaceLiveCase

      setup context do
        AllbertAssistWeb.WorkspaceLiveCase.workspace_live_setup(context)
      end
    end
  end

  def workspace_live_setup(_context) do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-agent-live-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    parent = self()

    runner = fn _signal, request ->
      send(parent, {:runtime_request, request})

      {:ok,
       %{message: "Runtime LiveView response: #{request.text}", status: :completed, actions: []}}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    _ = Session.clear_active_app("local", live_view_session_id())

    on_exit(fn ->
      _ = Session.clear_active_app("local", live_view_session_id())
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_config)
      restore_env(Settings, original_settings_config)
      remove_test_root!(root)
    end)

    {:ok, root: root}
  end

  def restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  def restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  def subscribe_actions do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.action.completed")
  end

  def receive_action_completed(action_name) do
    receive do
      {:signal, %{type: "allbert.action.completed", data: %{action_name: ^action_name}} = signal} ->
        signal

      {:signal, %{type: "allbert.action.completed"}} ->
        receive_action_completed(action_name)
    after
      1_000 -> flunk("expected action completion for #{action_name}")
    end
  end

  def create_workspace_thread(text \\ "Workspace test thread") do
    assert {:ok, thread} = Conversations.create_general_thread("local", text)
    thread
  end

  def workspace_thread_id(view) do
    html = render(view)
    assert [_, thread_id] = Regex.run(~r/data-thread-id="([^"]+)"/, html)
    thread_id
  end

  def ensure_stocksage_app_registered do
    plugin_registered? =
      match?({:ok, _entry}, AllbertAssist.Plugin.Registry.lookup("stocksage"))

    unless plugin_registered? do
      assert AllbertAssist.Plugin.Registry.register_module(StockSage.Plugin) in [
               {:ok, "stocksage"},
               {:error, {:plugin_id_taken, "stocksage"}}
             ]
    end

    app_registered? = AllbertAssist.App.Registry.known_app_id?(:stocksage)

    unless app_registered? do
      assert {:ok, :stocksage} = AllbertAssist.App.Registry.register(StockSage.App)
    end

    on_exit(fn ->
      unless app_registered?, do: AllbertAssist.App.Registry.unregister(:stocksage)
    end)
  end

  def render_until(view, text, attempts \\ 20)

  def render_until(view, text, attempts) when attempts > 0 do
    html = render(view)

    if html =~ text do
      html
    else
      Process.sleep(50)
      render_until(view, text, attempts - 1)
    end
  end

  def render_until(view, text, 0) do
    html = render(view)
    assert html =~ text
    html
  end

  def render_until_missing(view, selector, attempts \\ 20)

  def render_until_missing(view, selector, attempts) when attempts > 0 do
    if has_element?(view, selector) do
      Process.sleep(50)
      render_until_missing(view, selector, attempts - 1)
    else
      render(view)
    end
  end

  def render_until_missing(view, selector, 0) do
    refute has_element?(view, selector)
    render(view)
  end

  def remove_test_root!(root, attempts \\ 5)

  def remove_test_root!(root, 0), do: File.rm_rf!(root)

  def remove_test_root!(root, attempts) do
    case File.rm_rf(root) do
      {:ok, _paths} ->
        :ok

      {:error, :eexist, _path} ->
        Process.sleep(25)
        remove_test_root!(root, attempts - 1)

      {:error, reason, path} ->
        raise File.Error,
          action: "remove files and directories recursively from",
          path: path,
          reason: reason
    end
  end

  def live_view_session_id(external_user_id \\ "web-local") do
    Channels.derive_session_id("live_view", external_user_id, nil)
  end
end
