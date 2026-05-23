defmodule AllbertAssist.Security.OperatorReviewTest do
  use AllbertAssist.SecurityEvalCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.Guard
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias Mix.Tasks.Allbert.Security, as: SecurityTask
  alias StockSage.TraderBridge

  defmodule DisabledRegistrationPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "security.disabled_registration"

    @impl true
    def display_name, do: "Security Disabled Registration"

    @impl true
    def version, do: "0.28.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule DisabledRegistrationApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :security_disabled_registration

    @impl true
    def display_name, do: "Security Disabled Registration"

    @impl true
    def version, do: "0.28.0"

    @impl true
    def validate(_opts), do: :ok
  end

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v028-operator-review-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(home, "confirmations"))
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()
    PluginRegistry.register_module(StockSage.Plugin)

    on_exit(fn ->
      Guard.reset_for_test()
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.security")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "security-review-001: CLI review lists recent decisions and redaction events" do
    fixture = EvalInventory.row!("security-review-001")
    seed_review_confirmations!()

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run("security_review", %{limit: 10}, %{
                actor: "local",
                channel: :test,
                surface: "security_eval"
              })

            output = capture_io(fn -> assert :ok = SecurityTask.run(["review", "--recent"]) end)

            %{
              decision: if(response.status == :completed, do: :allowed, else: response.status),
              result: %{response: response, cli: output},
              trace: %{
                fixture_id: fixture.id,
                boundary: :security_review_cli,
                confirmation_count: length(response.security_review.confirmations),
                denial_count: length(response.security_review.denials),
                import_count: length(response.security_review.imports),
                external_call_count: length(response.security_review.external_calls),
                redaction_incident_count: length(response.security_review.redaction_incidents)
              }
            }
          end
        })
      )

    assert_allowed(eval)

    assert_trace_records(eval, [
      :confirmation_count,
      :denial_count,
      :import_count,
      :external_call_count,
      :redaction_incident_count
    ])

    assert eval.trace.confirmation_count >= 2
    assert eval.trace.denial_count >= 1
    assert eval.trace.import_count >= 1
    assert eval.trace.external_call_count >= 1
    assert eval.trace.redaction_incident_count >= 1
    assert eval.result.cli =~ "Security Review"
    assert eval.result.cli =~ "Recent confirmations:"
    assert eval.result.cli =~ "Recent denials:"
    assert eval.result.cli =~ "Emergency switches:"
    refute eval.result.cli =~ "sk-test-secret"
  end

  test "emergency-disable-001: settings switches flip the gated behavior" do
    fixture = EvalInventory.row!("emergency-disable-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            put_setting!("external_services.enabled", false)
            put_setting!("stocksage.bridge_enabled", false)
            put_setting!("plugins.registration_enabled", false)
            put_setting!("app_registry.registration_enabled", false)
            put_setting!("workspace.fragment.emission_enabled", false)

            plugin_registry =
              :"security_disabled_plugin_registry_#{System.unique_integer([:positive])}"

            plugin_table = :"security_disabled_plugin_table_#{System.unique_integer([:positive])}"
            app_registry = :"security_disabled_app_registry_#{System.unique_integer([:positive])}"
            app_table = :"security_disabled_app_table_#{System.unique_integer([:positive])}"

            app_supervisor =
              :"security_disabled_app_supervisor_#{System.unique_integer([:positive])}"

            bridge_name = :"security_disabled_bridge_#{System.unique_integer([:positive])}"

            start_supervised!({PluginRegistry, name: plugin_registry, table_name: plugin_table})

            start_supervised!(
              Supervisor.child_spec({AllbertAssist.App.DynamicSupervisor, name: app_supervisor},
                id: app_supervisor
              )
            )

            start_supervised!(
              Supervisor.child_spec(
                {AppRegistry,
                 name: app_registry, table_name: app_table, dynamic_supervisor: app_supervisor},
                id: app_registry
              )
            )

            start_supervised!({TraderBridge, name: bridge_name})

            {:ok, external_response} =
              Runner.run(
                "external_network_request",
                %{url: "https://example.com/status"},
                %{actor: "local", channel: :test}
              )

            plugin_result =
              PluginRegistry.register_module(DisabledRegistrationPlugin, server: plugin_registry)

            app_result = AppRegistry.register(DisabledRegistrationApp, server: app_registry)
            fragment_result = Fragment.emit(signed_envelope())
            bridge_status = TraderBridge.bridge_status(bridge_name)

            {:ok, review_response} =
              Runner.run("security_review", %{limit: 10}, %{actor: "local", channel: :test})

            disabled_switches =
              Enum.filter(review_response.security_review.emergency_switches, & &1.hard_disabled?)

            %{
              decision:
                if(
                  external_response.status == :denied and plugin_result == {:error, :disabled} and
                    app_result == {:error, :disabled} and
                    fragment_result == {:error, :emission_disabled} and
                    bridge_status == :disabled,
                  do: :allowed,
                  else: :denied
                ),
              result: %{
                external_response: external_response,
                plugin_result: plugin_result,
                app_result: app_result,
                fragment_result: fragment_result,
                bridge_status: bridge_status,
                disabled_switches: disabled_switches
              },
              trace: %{
                fixture_id: fixture.id,
                boundary: :settings_central,
                disabled_switch_count: length(disabled_switches),
                external_status: external_response.status,
                plugin_result: plugin_result,
                app_result: app_result,
                fragment_result: fragment_result,
                bridge_status: bridge_status
              }
            }
          end
        })
      )

    assert_allowed(eval)
    assert_trace_records(eval, [:disabled_switch_count, :external_status, :bridge_status])
    assert eval.trace.disabled_switch_count >= 5
    assert {:ok, []} = Workspace.canvas_tiles("thread-security-disabled", "alice")
  end

  defp seed_review_confirmations! do
    {:ok, external} =
      Confirmations.create(%{
        id: "conf_review_external",
        origin: %{actor: "local", channel: :cli, surface: "mix allbert.external"},
        target_action: %{name: "external_network_request"},
        target_permission: :external_network,
        target_execution_mode: :req_http,
        security_decision: %{
          permission: :external_network,
          decision: :needs_confirmation,
          reason: "External network access requires confirmation."
        },
        params_summary: %{url: "https://example.com/status", api_key: "sk-test-secret"}
      })

    {:ok, import} =
      Confirmations.create(%{
        id: "conf_review_import",
        origin: %{actor: "local", channel: :cli, surface: "mix allbert.skills"},
        target_action: %{name: "import_online_skill"},
        target_permission: :online_skill_import,
        target_execution_mode: :online_skill_import,
        security_decision: %{
          permission: :online_skill_import,
          decision: :needs_confirmation,
          reason: "Online skill import requires confirmation."
        },
        params_summary: %{url: "https://skills.sh/demo/SKILL.md"}
      })

    {:ok, _denied} =
      Confirmations.resolve(
        import["id"],
        :denied,
        %{
          resolver_actor: "local",
          resolver_channel: :cli,
          resolver_surface: "security-review-test",
          resolution_reason: "security review eval"
        }
      )

    external
  end

  defp signed_envelope(attrs \\ %{}) do
    secret = SigningSecret.ensure!()

    attrs =
      Map.merge(
        %{
          surface: valid_surface(),
          emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
          user_id: "alice",
          thread_id: "thread-security-disabled",
          scope: :canvas,
          kind: :text,
          emitted_at: ~U[2026-05-18 00:00:00Z]
        },
        attrs
      )

    assert {:ok, envelope} = Envelope.sign(attrs, secret)
    envelope
  end

  defp valid_surface do
    %Surface{
      id: :fragment,
      app_id: :allbert,
      label: "Fragment",
      path: "/workspace",
      kind: :canvas,
      status: :available,
      nodes: [%Node{id: "fragment-text", component: :text, props: %{text: "hello"}}],
      fallback_text: "Fragment fallback"
    }
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "security_eval", audit?: false}) do
      {:ok, _setting} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
