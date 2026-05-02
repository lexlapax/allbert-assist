defmodule AllbertAssistWeb.AgentLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Runtime

  setup do
    original_config = Application.get_env(:allbert_assist, Runtime)

    runner = fn _signal, request ->
      {:ok,
       %{message: "Runtime LiveView response: #{request.text}", status: :completed, actions: []}}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Runtime, original_config)
      else
        Application.delete_env(:allbert_assist, Runtime)
      end
    end)
  end

  test "submits prompts through the runtime boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Say hello from the runtime boundary."})

    html = render_async(view)

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

    html = render_async(view)

    assert has_element?(view, "#agent-response")
    assert html =~ "## Skill Context"
    assert html =~ "Name: append-memory"
    assert html =~ "Status: completed"
  end
end
