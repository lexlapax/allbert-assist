defmodule AllbertAssistWeb.WorkspaceSettingsCentralTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Marketplace, Paths, Settings}

  test "workspace settings destination renders Settings Central and updates through actions",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    html =
      view
      |> element("#workspace-dest-workspace-settings")
      |> render_click()

    assert html =~ "Settings Central"
    assert has_element?(view, "#workspace-settings-panel")
    refute has_element?(view, "[data-workspace-component='job_card']")
    refute has_element?(view, "[data-workspace-component='confirmation_card']")
    assert has_element?(view, "#settings-list")
    assert has_element?(view, "#settings-form")
    assert has_element?(view, "#workspace-theme-diagnostics")
    assert has_element?(view, "#workspace-theme-token-status")
    assert has_element?(view, "#workspace-theme-snippet-status")
    assert has_element?(view, "#workspace-layout-status")
    assert has_element?(view, "#security-status")
    assert has_element?(view, "#confirmation-requests")
    assert has_element?(view, "#remembered-resource-grants")
    assert has_element?(view, "#provider-key-form")
    assert has_element?(view, "#doctor-model-local")
    assert has_element?(view, "#use-model-local")

    subscribe_actions()

    html =
      view
      |> element("#settings-form")
      |> render_submit(%{
        "setting" => %{
          "key" => "operator.communication_style",
          "value" => "concise"
        }
      })

    assert html =~ "Setting saved."
    assert html =~ "settings-audit"
    assert {:ok, "concise"} = Settings.get("operator.communication_style")

    action_signal = receive_action_completed("update_setting")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :settings_write

    html =
      view
      |> element("#use-model-local")
      |> render_click()

    assert html =~ "Model profile saved."
    assert {:ok, "local"} = Settings.get("intent.model_profile")

    model_signal = receive_action_completed("set_active_model_profile")
    assert model_signal.data.status == :completed
    assert model_signal.data.permission_decision.permission == :settings_write
  end

  test "workspace create gallery only exposes Settings Central allowed patterns", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("templates.create.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("templates.allowed_patterns", ["llm_tool"], %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?#{[destination: "workspace:create"]}")

    assert has_element?(view, "#workspace-create-pattern-llm_tool")
    refute has_element?(view, "#workspace-create-pattern-plugin")
    refute has_element?(view, "#workspace-create-pattern-app")
    assert has_element?(view, "#workspace-create-param-permission")
    assert has_element?(view, "#workspace-create-mode-live:not([disabled])")
  end

  test "workspace Settings Central stores provider keys without exposing the secret", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#workspace-dest-workspace-settings")
    |> render_click()

    subscribe_actions()

    html =
      view
      |> element("#provider-key-form")
      |> render_submit(%{
        "provider" => %{
          "provider" => "openai",
          "api_key" => "sk-workspace-secret"
        }
      })

    assert html =~ "Provider credential saved."
    refute html =~ "sk-workspace-secret"

    action_signal = receive_action_completed("set_provider_credential")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :settings_secret_write
  end

  test "workspace create destination is denied when disabled", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace?destination=workspace:create")

    assert has_element?(view, "#workspace-dest-create")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:create']")
    assert has_element?(view, "#workspace-canvas[data-destination='workspace:create']")
    assert has_element?(view, "#workspace-create-panel[data-enabled='false']")
    assert has_element?(view, "#workspace-create-gallery")
    assert has_element?(view, "#workspace-create-params")
    assert has_element?(view, "#workspace-create-preview")
    assert has_element?(view, "#workspace-create-validate[data-validation-status='denied']")
    assert html =~ "Template creation is disabled by Settings Central."
  end

  test "workspace create renders gallery, params, preview, and validation", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")

    assert has_element?(view, "#workspace-create-panel[data-enabled='true']")
    assert has_element?(view, "#workspace-create-gallery")
    assert has_element?(view, "#workspace-create-params")
    assert has_element?(view, "#workspace-create-preview")
    assert has_element?(view, "#workspace-create-validate[data-validation-status='ready']")

    assert has_element?(
             view,
             "#workspace-create-pattern-llm_tool.workspace-create-pattern-active"
           )

    assert has_element?(view, "#workspace-create-mode-live:not([disabled])")

    html =
      view
      |> element("#workspace-create-params")
      |> render_change(%{
        "template" => %{
          "pattern_id" => "llm_tool",
          "mode" => "developer_scaffold",
          "name" => "custom_weather_tool",
          "description" => "Reviewed weather lookup.",
          "instruction" => "Return a concise response.",
          "permission" => "read_only",
          "version" => "0.1.0"
        }
      })

    assert html =~ "dynamic_manifest.json"
    assert html =~ "source/lib/action.ex"
    assert has_element?(view, "#workspace-create-validate[data-validation-status='ready']")
  end

  test "workspace create renders installed marketplace template metadata", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
    assert {:ok, _install} = Marketplace.install_bundle("allbert/workspace-brief")

    {:ok, view, html} = live(conn, ~p"/workspace?destination=workspace:create")

    assert has_element?(view, "#workspace-create-marketplace-templates[data-installed-count='1']")

    assert has_element?(
             view,
             "#workspace-create-marketplace-template-allbert-workspace-brief[data-entry-id='allbert/workspace-brief'][data-install-state='disabled_untrusted'][data-authority='metadata_only']"
           )

    assert html =~ "Workspace Brief"
    assert html =~ "marketplace_workspace_brief"
    assert html =~ "metadata.json"
    assert html =~ "template.md"
  end

  test "workspace create disables unsupported live mode", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")

    view
    |> element("#workspace-create-pattern-plugin")
    |> render_click()

    assert has_element?(view, "#workspace-create-mode-live[disabled]")
  end

  test "workspace create live submit fails closed when dynamic codegen is disabled", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})

    slug = "new_llm_tool"
    scaffold_target = Path.join(File.cwd!(), "plugins/#{slug}")
    draft_target = Path.join([Paths.home(), "dynamic_plugins", "drafts", slug])

    refute File.exists?(scaffold_target)
    refute File.exists?(draft_target)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")
    subscribe_actions()

    mode_html =
      view
      |> element("#workspace-create-mode-live")
      |> render_click()

    assert mode_html =~ ~s(data-output-mode="live_integration")
    assert has_element?(view, "#workspace-create-run:not([disabled])")

    html =
      view
      |> element("#workspace-create-run")
      |> render_click()

    assert html =~ "Template live draft was denied or unavailable"
    assert html =~ "dynamic_codegen_disabled"

    refute File.exists?(scaffold_target)
    refute File.exists?(draft_target)

    action_signal = receive_action_completed("create_from_template")
    assert action_signal.data.status == :denied
  end

  test "workspace create live submit fails closed when live loader is disabled", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})

    slug = "new_llm_tool"
    draft_target = Path.join([Paths.home(), "dynamic_plugins", "drafts", slug])

    refute File.exists?(draft_target)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")
    subscribe_actions()

    view
    |> element("#workspace-create-mode-live")
    |> render_click()

    html =
      view
      |> element("#workspace-create-run")
      |> render_click()

    assert html =~ "Template live draft was denied or unavailable"
    assert html =~ "dynamic_live_loader_disabled"

    refute File.exists?(draft_target)

    action_signal = receive_action_completed("create_from_template")
    assert action_signal.data.status == :denied
  end

  test "workspace create live submit writes only a templated dynamic draft", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.live_loader_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("sandbox.elixir.enabled", true, %{audit?: false})

    slug = "new_llm_tool"
    scaffold_target = Path.join(File.cwd!(), "plugins/#{slug}")
    draft_target = Path.join([Paths.home(), "dynamic_plugins", "drafts", slug])

    refute File.exists?(scaffold_target)
    refute File.exists?(draft_target)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")
    subscribe_actions()

    view
    |> element("#workspace-create-mode-live")
    |> render_click()

    html =
      view
      |> element("#workspace-create-run")
      |> render_click()

    assert html =~ "Templated dynamic draft #{slug} created."
    refute File.exists?(scaffold_target)
    assert File.regular?(Path.join(draft_target, "metadata.yaml"))

    assert File.read!(Path.join(draft_target, "metadata.yaml")) =~
             "template_pattern_id: llm_tool"

    action_signal = receive_action_completed("create_from_template")
    assert action_signal.data.status == :completed
  end
end
