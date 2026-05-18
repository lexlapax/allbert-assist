defmodule AllbertAssistWeb.AgentLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Objectives, Paths, Runtime, Settings, Workspace}
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias AllbertAssistWeb.SignalBridge

  @runtime_async_timeout 10_000

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

  test "mount renders workspace shell, chat fallback, and empty canvas placeholder", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agent")

    assert has_element?(view, "#workspace-shell")
    assert has_element?(view, "#agent-workspace-renderer")
    assert has_element?(view, "#workspace-chat-region")
    assert has_element?(view, "#agent-form")
    assert has_element?(view, "#workspace-node-workspace-canvas-region")
    assert has_element?(view, "#workspace-component-workspace-canvas-region")
    assert html =~ "canvas"
    refute html =~ "component not implemented"
  end

  test "mount applies workspace theme from settings", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("workspace.theme", "dark", %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/agent")

    assert has_element?(view, "#workspace-shell[data-theme='dark']")
  end

  test "renders emitted canvas fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")
    envelope = signed_envelope(%{surface: fragment_surface(:text, "Canvas fragment body")})

    Phoenix.PubSub.broadcast(
      AllbertAssistWeb.PubSub,
      SignalBridge.topic_for("local"),
      {:fragment, envelope}
    )

    html = render(view)

    assert has_element?(view, "#workspace-node-canvas-tile-#{envelope.id}")
    assert html =~ "Canvas fragment body"

    assert {:ok, [tile]} = Workspace.canvas_tiles("local-default", "local")
    assert tile.id == envelope.id
  end

  test "renders emitted ephemeral fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    envelope =
      signed_envelope(%{
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Approval fragment body")
      })

    Phoenix.PubSub.broadcast(
      AllbertAssistWeb.PubSub,
      SignalBridge.topic_for("local"),
      {:fragment, envelope}
    )

    html = render(view)

    assert has_element?(view, "#workspace-node-ephemeral-surface-#{envelope.id}")
    assert html =~ "Approval fragment body"

    assert {:ok, [surface]} = Workspace.ephemeral_surfaces("local-default", "local")
    assert surface.id == envelope.id
  end

  test "renders canvas-header badge fragments without persisting them as tiles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    envelope =
      signed_envelope(%{
        emitter_id: "AllbertAssist.Workspace.Canvas",
        kind: :badge_strip,
        metadata: %{placement: "canvas_header"},
        surface: fragment_surface(:status_badge, "1 older tile(s) archived")
      })

    Phoenix.PubSub.broadcast(
      AllbertAssistWeb.PubSub,
      SignalBridge.topic_for("local"),
      {:fragment, envelope}
    )

    html = render(view)

    assert html =~ "Workspace notices"
    assert html =~ "1 older tile(s) archived"
    assert {:ok, []} = Workspace.canvas_tiles("local-default", "local")
  end

  test "submits prompts through the runtime boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Say hello from the runtime boundary."})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "Runtime LiveView response: Say hello from the runtime boundary."
    assert html =~ "Status: completed"
    assert has_element?(view, "#agent-signal")
  end

  test "renders active objective badge from registered action boundary", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "blocked",
               active_app: "stocksage"
             })

    {:ok, view, html} = live(conn, ~p"/agent")

    assert html =~ "Analyze AAPL"
    assert has_element?(view, "#objective-badge-#{objective.id}")
  end

  test "default runtime can activate a skill through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Activate skill append-memory"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "## Skill Context"
    assert html =~ "Name: append-memory"
    assert html =~ "Status: completed"
  end

  test "default runtime renders URL summarization approval through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "check https://example.com/report and summarize it"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "External network request is ready"
    assert html =~ "Status: needs_confirmation"
    assert html =~ "Resource remote_url summarize_url summarize"
    assert html =~ "consumer=url_summarizer"
    assert has_element?(view, "#approval-handoff")
    assert [_pending] = Confirmations.list(status: :pending)
  end

  test "default runtime renders approval handoff and resolves denial through actions", %{
    conn: conn
  } do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Fetch https://example.com from the internet"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#approval-handoff")
    assert html =~ "Approval Required"
    assert html =~ "external_network_request"
    assert html =~ "Resource remote_url external_service_request fetch"
    assert has_element?(view, "#approval-approve")
    assert has_element?(view, "#approval-deny")
    assert has_element?(view, "#approval-details")

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "external_network_request"

    deny_html =
      view
      |> element("#approval-deny")
      |> render_click()

    assert deny_html =~ "Confirmation #{pending["id"]} is denied."
    assert {:ok, denied} = Confirmations.read(pending["id"])
    assert denied["status"] == "denied"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp signed_envelope(attrs) do
    secret = SigningSecret.ensure!()

    attrs =
      Map.merge(
        %{
          surface: fragment_surface(:text, "Fragment body"),
          emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
          user_id: "local",
          thread_id: "local-default",
          scope: :canvas,
          kind: :text,
          emitted_at: ~U[2026-05-18 00:00:00Z]
        },
        attrs
      )

    assert {:ok, envelope} = Envelope.sign(attrs, secret)
    envelope
  end

  defp fragment_surface(component, body) do
    %Surface{
      id: :fragment,
      app_id: :allbert,
      label: "Fragment",
      path: "/agent",
      kind: :canvas,
      status: :available,
      nodes: [
        %Node{
          id: "fragment-#{component}",
          component: component,
          props: %{title: "Fragment", body: body}
        }
      ],
      fallback_text: "Fragment fallback"
    }
  end
end
