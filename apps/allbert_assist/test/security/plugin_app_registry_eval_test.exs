defmodule AllbertAssist.Security.PluginAppRegistryEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.SecurityFixtures.EvalInventory

  defmodule ForeignStockSageApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :stocksage

    @impl true
    def display_name, do: "Foreign StockSage"

    @impl true
    def version, do: "0.28.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule DisabledActionPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "security.disabled_action"

    @impl true
    def display_name, do: "Security Disabled Action"

    @impl true
    def version, do: "0.28.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [AllbertAssist.Actions.Intent.DirectAnswer]
  end

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v028-plugin-app-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    plugin_registry = :"security_plugin_registry_#{System.unique_integer([:positive])}"
    plugin_table = :"security_plugin_table_#{System.unique_integer([:positive])}"
    app_registry = :"security_app_registry_#{System.unique_integer([:positive])}"
    app_table = :"security_app_table_#{System.unique_integer([:positive])}"
    app_supervisor = :"security_app_supervisor_#{System.unique_integer([:positive])}"

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

    stocksage_app_registered? = AppRegistry.known_app_id?(:stocksage)
    ensure_stocksage_plugin!()
    unless stocksage_app_registered?, do: AppRegistry.register(StockSage.App)

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      unless stocksage_app_registered?, do: AppRegistry.unregister(:stocksage)
      File.rm_rf!(root)
    end)

    {:ok, plugin_registry: plugin_registry, app_registry: app_registry, root: root}
  end

  test "app-id-claim-001: foreign app cannot claim StockSage app id", %{
    app_registry: app_registry
  } do
    fixture = EvalInventory.row!("app-id-claim-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            case AppRegistry.register(ForeignStockSageApp, server: app_registry) do
              {:error, reason} ->
                %{
                  decision: :error,
                  result: %{error: reason},
                  trace: %{
                    fixture_id: fixture.id,
                    boundary: :app_registry,
                    app_id: :stocksage,
                    claim_status: :rejected
                  }
                }

              {:ok, app_id} ->
                %{decision: :allowed, result: %{app_id: app_id}, trace: %{fixture_id: fixture.id}}
            end
          end
        })
      )

    assert eval.decision == :error
    assert {:reserved_app_id, :stocksage} = eval.result.error
    assert AppRegistry.registered_apps(server: app_registry) == []
  end

  test "app-scope-route-001: StockSage RunAnalysis is denied from allbert app scope" do
    fixture = EvalInventory.row!("app-scope-route-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "run_analysis",
                %{
                  ticker: "AAPL",
                  analysis_date: "2026-05-22",
                  user_id: "alice",
                  force_stub: true
                },
                %{active_app: :allbert, actor: "alice", channel: :test}
              )

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                boundary: :runner_app_scope,
                active_app: :allbert,
                expected_app: :stocksage,
                confirmations_created: Confirmations.list(status: :pending) |> length()
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert eval.result.error == {:app_scope_denied, :app_scope_mismatch}

    assert get_in(eval.result.actions, [Access.at(0), :app_scope]) == %{
             expected_app: :stocksage,
             active_app: :allbert
           }

    assert eval.trace.confirmations_created == 0
  end

  test "disabled-plugin-001: disabled plugin entries expose no runtime contributions", %{
    plugin_registry: plugin_registry
  } do
    fixture = EvalInventory.row!("disabled-plugin-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            result =
              PluginRegistry.register_module(DisabledActionPlugin,
                server: plugin_registry,
                status: :disabled
              )

            %{
              decision: if(match?({:ok, _}, result), do: :denied, else: :error),
              result: %{
                registration: result,
                actions: PluginRegistry.registered_actions(server: plugin_registry)
              },
              trace: %{
                fixture_id: fixture.id,
                boundary: :plugin_registry,
                registered_plugin_count:
                  PluginRegistry.registered_plugins(server: plugin_registry) |> length()
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert {:ok, "security.disabled_action"} = eval.result.registration
    assert eval.result.actions == []
    assert eval.trace.registered_plugin_count == 0

    assert {:ok, entry} =
             PluginRegistry.lookup("security.disabled_action", server: plugin_registry)

    assert entry.status == :disabled
  end

  test "skill-root-traversal-001: manifest skill paths must stay inside plugin root", %{
    plugin_registry: plugin_registry,
    root: root
  } do
    fixture = EvalInventory.row!("skill-root-traversal-001")
    plugin_root = Path.join(root, "traversal-plugin")
    File.mkdir_p!(plugin_root)

    manifest = %{
      "schema_version" => 1,
      "plugin_id" => "security.traversal",
      "name" => "Security Traversal",
      "version" => "0.28.0",
      "kind" => "skills",
      "skill_paths" => ["../escape"]
    }

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            result =
              PluginRegistry.register_manifest(manifest,
                server: plugin_registry,
                source: :home,
                root_path: plugin_root
              )

            %{
              decision: if(match?({:error, _}, result), do: :error, else: :allowed),
              result: %{
                registration: result,
                skill_paths: PluginRegistry.registered_skill_paths(server: plugin_registry)
              },
              trace: %{
                fixture_id: fixture.id,
                boundary: :plugin_validator,
                diagnostics:
                  Map.get(
                    PluginRegistry.diagnostics(server: plugin_registry),
                    "security.traversal"
                  )
              }
            }
          end
        })
      )

    assert eval.decision == :error
    assert {:error, :invalid} = eval.result.registration
    assert eval.result.skill_paths == []
    assert Enum.any?(eval.trace.diagnostics, &(&1.kind == :invalid_skill_path))
  end

  test "home-plugin-code-001: home manifests cannot contribute code-bearing modules", %{
    plugin_registry: plugin_registry,
    root: root
  } do
    fixture = EvalInventory.row!("home-plugin-code-001")
    plugin_root = Path.join(root, "home-code-plugin")
    skills_root = Path.join(plugin_root, "skills")
    File.mkdir_p!(skills_root)

    manifest = %{
      "schema_version" => 1,
      "plugin_id" => "security.home_code",
      "name" => "Security Home Code",
      "version" => "0.28.0",
      "kind" => "mixed",
      "module" => "Security.HomeCode",
      "skill_paths" => ["skills"],
      "contributions" => %{
        "actions" => ["Security.HomeCode.Action"]
      }
    }

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            result =
              PluginRegistry.register_manifest(manifest,
                server: plugin_registry,
                source: :home,
                root_path: plugin_root
              )

            %{
              decision: if(match?({:error, :rejected}, result), do: :denied, else: :allowed),
              result: %{
                registration: result,
                actions: PluginRegistry.registered_actions(server: plugin_registry)
              },
              trace: %{
                fixture_id: fixture.id,
                boundary: :plugin_registry,
                diagnostics:
                  Map.get(
                    PluginRegistry.diagnostics(server: plugin_registry),
                    "security.home_code"
                  )
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert {:error, :rejected} = eval.result.registration
    assert eval.result.actions == []
    assert Enum.any?(eval.trace.diagnostics, &(&1.kind == :code_bearing_home_plugin))
  end

  defp ensure_stocksage_plugin! do
    case PluginRegistry.lookup("stocksage") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
