defmodule AllbertAssistWeb.SettingsLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Settings

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-settings-live-#{System.unique_integer([:positive])}")

    settings_root = Path.join(root, "settings")
    confirmations_root = Path.join(root, "confirmations")
    Application.put_env(:allbert_assist, Confirmations, root: confirmations_root)
    Application.put_env(:allbert_assist, Settings, root: settings_root)

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root, settings_root: settings_root}
  end

  test "renders settings and provider profiles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-list")
    assert has_element?(view, "#settings-key")
    assert has_element?(view, "#settings-value")
    assert has_element?(view, "#settings-save")
    assert has_element?(view, "#settings-explanation")
    assert has_element?(view, "#settings-diagnostics")
    assert has_element?(view, "#security-status")
    assert has_element?(view, "#security-permission-defaults")
    assert has_element?(view, "#security-safety-floors")
    assert has_element?(view, "#security-skill-trust-summary")
    assert has_element?(view, "#security-secret-status")
    assert has_element?(view, "#security-redaction-posture")
    assert has_element?(view, "#security-future-boundaries")
    assert has_element?(view, "#confirmation-requests")
    assert has_element?(view, "#pending-confirmations")
    assert has_element?(view, "#resolved-confirmations")
    assert has_element?(view, "#provider-profiles")
    assert has_element?(view, "#provider-key-form")
  end

  test "selecting and saving a safe setting updates yaml", %{
    conn: conn,
    settings_root: settings_root
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> element("button[phx-value-key='operator.timezone']")
    |> render_click()

    assert render(view) =~ "operator.timezone"

    view
    |> form("#settings-form",
      setting: %{"key" => "operator.communication_style", "value" => "balanced"}
    )
    |> render_submit()

    assert {:ok, "balanced"} = Settings.get("operator.communication_style")

    assert File.read!(Path.join(settings_root, "settings.yml")) =~
             "communication_style: balanced"

    assert has_element?(view, "#settings-audit")
  end

  test "invalid setting value shows diagnostics", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("#settings-form",
        setting: %{"key" => "operator.communication_style", "value" => "purple"}
      )
      |> render_submit()

    assert html =~ "invalid_setting"
    assert has_element?(view, "#settings-diagnostics")
  end

  test "security section edits permission settings and shows effective safety floors", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("#permission-command-execute-form",
        permission: %{"key" => "permissions.command_execute", "value" => "allowed"}
      )
      |> render_submit()

    assert {:ok, "allowed"} = Settings.get("permissions.command_execute")
    assert html =~ "command_execute"
    assert html =~ "Effective: denied"
    assert html =~ "Capped: true"
    refute html =~ "secret://"
  end

  test "provider key form stores secret and clears raw value from html", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("#provider-key-form",
        provider: %{"provider" => "openai", "api_key" => "test-key"}
      )
      |> render_submit()

    assert html =~ "Credential: configured"
    refute html =~ "test-key"
    assert {:ok, "test-key"} = Settings.Secrets.get_secret("secret://providers/openai/api_key")
  end

  test "renders pending confirmations and approves through the action boundary", %{conn: conn} do
    assert {:ok, record} =
             Confirmations.create(
               base_confirmation_attrs("conf_live_approve", %{api_key: "live-secret"})
             )

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#confirmation-pending-#{record["id"]}")
    assert render(view) =~ "external_network_request"
    refute render(view) =~ "live-secret"

    html =
      view
      |> element("#approve-confirmation-#{record["id"]}")
      |> render_click()

    assert html =~ "adapter_unavailable"
    assert has_element?(view, "#confirmation-resolved-#{record["id"]}")

    assert {:ok, resolved} = Confirmations.read(record["id"])
    assert resolved["status"] == "adapter_unavailable"
    assert resolved["operator_resolution"]["resolver_channel"] == "live_view"
  end

  test "denies confirmations through LiveView and respects disabled approval setting", %{
    conn: conn
  } do
    assert {:ok, _setting} =
             Settings.put("confirmations.allow_liveview_approval", false, %{audit?: false})

    assert {:ok, approve_candidate} =
             Confirmations.create(base_confirmation_attrs("conf_live_disabled", %{}))

    assert {:ok, deny_candidate} =
             Confirmations.create(base_confirmation_attrs("conf_live_deny", %{}))

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#approve-confirmation-#{approve_candidate["id"]}[disabled]")

    html =
      view
      |> form("#deny-confirmation-#{deny_candidate["id"]}-form",
        confirmation: %{"id" => deny_candidate["id"], "reason" => "not now"}
      )
      |> render_submit()

    assert html =~ "denied"
    assert has_element?(view, "#confirmation-resolved-#{deny_candidate["id"]}")

    assert {:ok, denied} = Confirmations.read(deny_candidate["id"])
    assert denied["status"] == "denied"
    assert denied["operator_resolution"]["resolver_channel"] == "live_view"
  end

  defp base_confirmation_attrs(id, params_summary) do
    %{
      id: id,
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      selected_skill: %{name: "append-memory", trust_status: :trusted},
      security_decision: %{
        permission: :external_network,
        decision: :needs_confirmation,
        risk: %{tier: :high}
      },
      params_summary: params_summary
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
