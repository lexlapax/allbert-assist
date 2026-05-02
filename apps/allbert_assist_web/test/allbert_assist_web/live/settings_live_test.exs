defmodule AllbertAssistWeb.SettingsLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-settings-live-#{System.unique_integer([:positive])}")

    settings_root = Path.join(root, "settings")
    Application.put_env(:allbert_assist, Settings, root: settings_root)

    on_exit(fn ->
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
