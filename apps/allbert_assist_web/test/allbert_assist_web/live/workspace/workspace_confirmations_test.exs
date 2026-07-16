defmodule AllbertAssistWeb.WorkspaceConfirmationsTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Runtime}
  alias AllbertAssist.Resources.{Grants, ResourceURI, Scope}

  @runtime_async_timeout 60_000

  test "workspace Settings Central approves, denies, and revokes through registered actions",
       %{conn: conn} do
    assert {:ok, approve_candidate} =
             Confirmations.create(confirmation_attrs("conf_workspace_settings_approve"))

    assert {:ok, deny_candidate} =
             Confirmations.create(confirmation_attrs("conf_workspace_settings_deny"))

    assert {:ok, grant} =
             Grants.remember(external_ref("https://example.com/settings-central"),
               id: "grant_workspace_settings",
               reason: "workspace settings test",
               audit?: false
             )

    {:ok, view, _html} = live(conn, ~p"/workspace")

    html =
      view
      |> element("#workspace-dest-workspace-settings")
      |> render_click()

    assert html =~ approve_candidate["id"]
    assert html =~ deny_candidate["id"]
    assert html =~ grant["id"]

    subscribe_actions()

    view
    |> element("#approve-confirmation-#{approve_candidate["id"]}")
    |> render_click()

    approve_signal = receive_action_completed("approve_confirmation")
    assert approve_signal.data.status == :completed
    assert {:ok, approved} = Confirmations.read(approve_candidate["id"])
    refute approved["status"] == "pending"

    view
    |> element("#deny-confirmation-#{deny_candidate["id"]}-form")
    |> render_submit(%{
      "confirmation" => %{"id" => deny_candidate["id"], "reason" => "not needed"}
    })

    deny_signal = receive_action_completed("deny_confirmation")
    assert deny_signal.data.status == :completed
    assert {:ok, denied} = Confirmations.read(deny_candidate["id"])
    assert denied["status"] == "denied"

    view
    |> element("#revoke-resource-grant-#{grant["id"]}")
    |> render_click()

    revoke_signal = receive_action_completed("revoke_resource_grant")
    assert revoke_signal.data.status == :completed

    assert {:error, {:grant_revoked, "grant_workspace_settings"}} =
             Grants.find_applicable(external_ref("https://example.com/settings-central"),
               permission: :external_network
             )
  end

  # v1.0.1 M4.2.3 (ADR 0073): the web composer intercepts typed confirmation
  # callbacks through the shared Channels.ConfirmationCallback guard — the
  # TUI/Slack/Telegram analogue — instead of routing them into the intent
  # router as free text.
  test "typed confirmation callbacks resolve in the composer without an intent turn",
       %{conn: conn} do
    assert {:ok, candidate} = Confirmations.create(confirmation_attrs("conf_typed_web_approve"))

    {:ok, view, _html} = live(conn, ~p"/workspace")

    show_html =
      view
      |> element("#agent-form")
      |> render_submit(%{"prompt" => "ALLBERT:SHOW:#{candidate["id"]}"})

    assert show_html =~ "Confirmation #{candidate["id"]}: pending."
    assert {:ok, %{"status" => "pending"}} = Confirmations.read(candidate["id"])

    approve_html =
      view
      |> element("#agent-form")
      |> render_submit(%{"prompt" => "ALLBERT:APPROVE:#{candidate["id"]}"})

    assert {:ok, approved} = Confirmations.read(candidate["id"])
    refute approved["status"] == "pending"
    assert has_element?(view, "#agent-response")
    assert approve_html =~ "Confirmation #{candidate["id"]} is #{approved["status"]}."

    # The typed command never became an intent-routed runtime turn.
    refute_receive {:runtime_request, _request}, 100
  end

  test "typed approval for a foreign-channel confirmation renders the rejection honestly",
       %{conn: conn} do
    attrs = confirmation_attrs("conf_typed_wrong_channel")
    attrs = %{attrs | origin: %{actor: "local", channel: :tui, surface: "tui_prompt"}}
    assert {:ok, candidate} = Confirmations.create(attrs)

    {:ok, view, _html} = live(conn, ~p"/workspace")

    html =
      view
      |> element("#agent-form")
      |> render_submit(%{"prompt" => "ALLBERT:APPROVE:#{candidate["id"]}"})

    assert html =~ "Confirmation approve for #{candidate["id"]} was not applied:"
    assert html =~ "this confirmation expects resolution from its origin channel"
    assert {:ok, %{"status" => "pending"}} = Confirmations.read(candidate["id"])
    refute_receive {:runtime_request, _request}, 100
  end

  # v1.0.1 M4.2.3: the Settings Central pending queue live-updates on
  # confirmation lifecycle signals instead of snapshotting at panel-open.
  test "settings central pending queue live-appends and removes confirmations while open",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:settings")
    thread_id = workspace_thread_id(view)

    assert has_element?(view, "#workspace-settings-panel")
    assert has_element?(view, "#no-pending-confirmations")

    attrs = confirmation_attrs("conf_settings_live_append")

    attrs = %{
      attrs
      | origin: Map.merge(attrs.origin, %{user_id: "local", thread_id: thread_id})
    }

    assert {:ok, candidate} = Confirmations.create(attrs)

    html = render_until(view, "confirmation-pending-#{candidate["id"]}")
    assert html =~ candidate["id"]

    assert {:ok, _resolved} = Confirmations.resolve(candidate["id"], :denied)

    render_until_missing(view, "#confirmation-pending-#{candidate["id"]}")
    assert has_element?(view, "#no-pending-confirmations")
  end

  test "approval handoff remains visible when response status is not needs_confirmation", %{
    conn: conn
  } do
    parent = self()

    runner = fn _signal, request ->
      send(parent, {:runtime_request, request})

      {:ok,
       %{
         message: "Approval response for #{request.text}",
         status: :completed,
         actions: [],
         approval_handoff: %{
           confirmation_id: "conf_completed_handoff",
           status: :pending,
           target_action: %{action: %{name: "external_network_request"}},
           resource_access: [
             %{
               origin_kind: :remote_url,
               operation_class: :external_service_request,
               access_mode: :fetch,
               scope: %{kind: :url, value: "https://example.com/"}
             }
           ],
           allowed_actions: [:approve, :deny, :details],
           render_hints: %{target_label: "external_network_request"}
         }
       }}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Fetch https://example.com from the internet"})

    html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, %{text: "Fetch https://example.com from the internet"}}
    assert has_element?(view, "#agent-response")
    assert has_element?(view, "#approval-handoff")
    assert has_element?(view, "#approval-approve:not([disabled])")
    assert html =~ "conf_completed_handoff"
    assert html =~ "external_network_request"
    assert html =~ "Resource remote_url external_service_request fetch"
  end

  defp confirmation_attrs(id) do
    %{
      id: id,
      origin: %{actor: "local", channel: :live_view, surface: "/workspace"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{
        url: "https://example.com/settings-central",
        resource_refs: [external_ref("https://example.com/settings-central")]
      }
    }
  end

  defp external_ref(url) do
    %{
      resource_uri: ResourceURI.url!(url),
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :external_service_request,
      access_mode: :fetch,
      scope: Scope.to_map(Scope.exact_url(url)),
      downstream_consumer: :req_http
    }
  end
end
