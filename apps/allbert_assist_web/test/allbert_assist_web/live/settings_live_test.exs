defmodule AllbertAssistWeb.SettingsLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_audit_config = Application.get_env(:allbert_assist, Audit)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-settings-live-#{System.unique_integer([:positive])}")

    settings_root = Path.join(root, "settings")
    home = Path.join(root, "home")
    confirmations_root = Path.join(root, "confirmations")

    Application.put_env(:allbert_assist, Paths,
      home: home,
      skills_root: Path.join(home, "skills")
    )

    Application.put_env(:allbert_assist, Confirmations, root: confirmations_root)
    Application.put_env(:allbert_assist, Audit, root: Path.join(root, "execution"))
    Application.put_env(:allbert_assist, Settings, root: settings_root)

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Audit, original_audit_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root, home: home, settings_root: settings_root}
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
    assert has_element?(view, "#security-v010-capabilities")
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
    assert html =~ "Effective: needs_confirmation"
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
    assert html =~ "Approved, but not executed"
    assert html =~ "New v0.10 external-network requests use the confirmed Req adapter."
    assert has_element?(view, "#confirmation-resolved-#{record["id"]}")

    assert {:ok, resolved} = Confirmations.read(record["id"])
    assert resolved["status"] == "adapter_unavailable"
    assert resolved["operator_resolution"]["resolver_channel"] == "live_view"
  end

  test "renders and approves shell command confirmation metadata", %{conn: conn, root: root} do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "live shell fixture\n")
    put_execution_policy!(workspace)

    assert {:ok, pending_response} =
             Runner.run(
               "run_shell_command",
               %{executable: "pwd", args: [], cwd: workspace},
               %{actor: "local", channel: :live_view, surface: "/settings"}
             )

    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "run_shell_command"
    assert html =~ "Command: pwd"
    assert html =~ "Cwd: #{workspace}"
    assert has_element?(view, "#confirmation-details-#{pending_response.confirmation_id}")

    approved_html =
      view
      |> element("#approve-confirmation-#{pending_response.confirmation_id}")
      |> render_click()

    assert approved_html =~ "status approved"
    assert approved_html =~ "Result: completed"
    assert approved_html =~ "Output preview:"
    assert approved_html =~ Path.basename(workspace)
    assert has_element?(view, "#confirmation-result-#{pending_response.confirmation_id}")

    assert {:ok, resolved} = Confirmations.read(pending_response.confirmation_id)
    assert resolved["status"] == "approved"
    assert resolved["operator_resolution"]["target_resumed?"]
    assert resolved["operator_resolution"]["target_status"] == "completed"
  end

  test "renders and approves skill script confirmation metadata", %{
    conn: conn,
    root: root,
    home: home
  } do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    write_script_skill!(home, "demo-script")
    put_script_policy!(workspace)

    assert {:ok, pending_response} =
             Runner.run(
               "run_skill_script",
               %{
                 skill_name: "demo-script",
                 script_path: "scripts/hello",
                 args: [],
                 cwd: workspace
               },
               %{actor: "local", channel: :live_view, surface: "/settings"}
             )

    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "run_skill_script"
    assert html =~ "Skill: demo-script"
    assert html =~ "Script: scripts/hello"
    assert has_element?(view, "#confirmation-details-#{pending_response.confirmation_id}")

    approved_html =
      view
      |> element("#approve-confirmation-#{pending_response.confirmation_id}")
      |> render_click()

    assert approved_html =~ "status approved"
    assert approved_html =~ "Result: completed"
    assert approved_html =~ "Output preview: hello from demo-script"
    assert has_element?(view, "#confirmation-result-#{pending_response.confirmation_id}")

    assert {:ok, resolved} = Confirmations.read(pending_response.confirmation_id)
    assert resolved["status"] == "approved"
    assert resolved["operator_resolution"]["target_resumed?"]
    assert resolved["operator_resolution"]["target_status"] == "completed"
  end

  test "renders v0.10 external package and online confirmation metadata", %{
    conn: conn,
    root: root
  } do
    external_id = "conf_live_external_v010"
    package_id = "conf_live_package_v010"
    online_id = "conf_live_online_v010"

    assert {:ok, _external} =
             Confirmations.create(
               v010_external_attrs(external_id),
               now: DateTime.from_unix!(1_700_000_000)
             )

    assert {:ok, _external_resolved} =
             Confirmations.resolve(
               external_id,
               :approved,
               resolution_attrs(%{
                 target_status: :completed,
                 target_result: %{
                   status: :completed,
                   http_status: 200,
                   duration_ms: 12,
                   body_preview: "ok",
                   response_body_bytes: 2,
                   truncated?: false
                 }
               })
             )

    assert {:ok, _package} =
             Confirmations.create(
               v010_package_attrs(package_id, Path.join(root, "workspace")),
               now: DateTime.from_unix!(1_700_000_001)
             )

    assert {:ok, _package_resolved} =
             Confirmations.resolve(
               package_id,
               :approved,
               resolution_attrs(%{
                 target_status: :completed,
                 target_result: %{
                   status: :completed,
                   exit_status: 0,
                   stdout_preview: "fake npm install left-pad@1.3.0",
                   output_bytes: 36,
                   truncated?: false
                 }
               })
             )

    assert {:ok, _online} =
             Confirmations.create(
               v010_online_attrs(online_id, root),
               now: DateTime.from_unix!(1_700_000_002)
             )

    assert {:ok, _online_resolved} =
             Confirmations.resolve(
               online_id,
               :approved,
               resolution_attrs(%{
                 target_status: :completed,
                 target_result: %{
                   status: :imported_disabled,
                   target_root: Path.join([root, "cache", "skills", "skills_sh", "demo"]),
                   manifest_path: Path.join([root, "cache", "skills", "_sources", "demo.json"]),
                   audit: %{status: :passed}
                 }
               })
             )

    {:ok, view, html} = live(conn, ~p"/settings")

    assert html =~ "v0.10 Capabilities"
    assert html =~ "External services:"
    assert has_element?(view, "#confirmation-result-#{external_id}")
    assert html =~ "Method: GET"
    assert html =~ "Body preview: ok"
    assert has_element?(view, "#confirmation-result-#{package_id}")
    assert html =~ "Manager: npm"
    assert html =~ "fake npm install left-pad@1.3.0"
    assert has_element?(view, "#confirmation-result-#{online_id}")
    assert html =~ "Imported target:"
    assert html =~ "Audit: passed"
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

  defp put_execution_policy!(workspace) do
    settings = %{
      "permissions" => %{"command_execute" => "allowed"},
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace]
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp put_script_policy!(workspace) do
    settings = %{
      "permissions" => %{"skill_script_execute" => "allowed"},
      "execution" => %{
        "local" => %{"allowed_roots" => [workspace]},
        "skill_scripts" => %{"enabled" => true}
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp v010_external_attrs(id) do
    %{
      id: id,
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.external"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :req_http,
      security_decision: base_security(:external_network),
      params_summary: %{
        method: "GET",
        url: "https://example.com/status",
        profile: "default",
        host: "example.com",
        path: "/status",
        timeout_ms: 5000,
        max_response_bytes: 1024,
        allow_redirects?: false,
        retry_policy: "none"
      }
    }
  end

  defp v010_package_attrs(id, workspace) do
    %{
      id: id,
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.packages"},
      target_action: %{name: "run_package_install"},
      target_permission: :package_install,
      target_execution_mode: :package_manager_process,
      security_decision: base_security(:package_install),
      params_summary: %{
        manager: "npm",
        packages: ["left-pad@1.3.0"],
        resolved_target_root: workspace,
        execution_argv_preview: [
          "npm",
          "install",
          "left-pad@1.3.0",
          "--ignore-scripts",
          "--allow-git=none"
        ],
        execution_available?: true,
        timeout_ms: 30_000,
        max_output_bytes: 65_536
      }
    }
  end

  defp v010_online_attrs(id, root) do
    %{
      id: id,
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.skills"},
      target_action: %{name: "import_online_skill"},
      target_permission: :online_skill_import,
      target_execution_mode: :online_skill_import,
      security_decision: base_security(:online_skill_import),
      params_summary: %{
        source: %{
          id: "skills_sh",
          base_url: "https://skills.sh",
          api_url: "https://skills.sh/api"
        },
        id: "demo/imported-skill"
      },
      resume_params_ref: %{source: "skills_sh", id: "demo/imported-skill"},
      source_trace_id: Path.join([root, "traces", "demo.md"])
    }
  end

  defp base_security(permission) do
    %{permission: permission, decision: :needs_confirmation, risk: %{tier: :high}}
  end

  defp resolution_attrs(extra) do
    Map.merge(
      %{
        resolver_actor: "local",
        resolver_channel: :live_view,
        resolver_surface: "/settings",
        target_resumed?: true
      },
      extra
    )
  end

  defp write_script_skill!(home, name) do
    skill_root = Path.join([home, "skills", name])
    script_path = Path.join([skill_root, "scripts", "hello"])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(Path.join(skill_root, "SKILL.md"), skill_markdown(name))
    File.write!(script_path, "#!/bin/sh\nprintf 'hello from #{name}\\n'\n")
    File.chmod!(script_path, 0o755)
  end

  defp skill_markdown(name) do
    """
    ---
    name: #{name}
    description: #{name} test script skill.
    metadata:
      allbert.kind: capability
      allbert.actions: run_skill_script
      allbert.permissions: skill_script_execute
      allbert.confirmation: required
    ---

    Run only through Allbert.
    """
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
