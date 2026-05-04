defmodule AllbertAssistWeb.AgentLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Paths, Runtime, Settings}

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-agent-live-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    runner = fn _signal, request ->
      {:ok,
       %{message: "Runtime LiveView response: #{request.text}", status: :completed, actions: []}}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)
  end

  test "submits prompts through the runtime boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Say hello from the runtime boundary."})

    html = render_async(view, 1_000)

    assert has_element?(view, "#agent-response")
    assert html =~ "Runtime LiveView response: Say hello from the runtime boundary."
    assert html =~ "Status: completed"
    assert has_element?(view, "#agent-signal")
  end

  test "default runtime can activate a skill through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Activate skill append-memory"})

    html = render_async(view, 1_000)

    assert has_element?(view, "#agent-response")
    assert html =~ "## Skill Context"
    assert html =~ "Name: append-memory"
    assert html =~ "Status: completed"
  end

  test "default runtime renders unsupported URL summarization through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "check https://example.com/report and summarize it"})

    html = render_async(view, 1_000)

    assert has_element?(view, "#agent-response")
    assert html =~ "URL summarization is deferred to v0.11"
    assert html =~ "Status: unsupported"
    assert Confirmations.list(status: :pending) == []
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
