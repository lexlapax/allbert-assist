defmodule AllbertAssist.Security.PluginAppRegistryEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Runner, as: JobsRunner
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings

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

  test "app-scope-missing-001: StockSage RunAnalysis requires explicit StockSage app scope" do
    fixture = EvalInventory.row!("app-scope-missing-001")

    params = %{
      ticker: "AAPL",
      analysis_date: "2026-05-22",
      user_id: "alice",
      force_stub: true
    }

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, missing_response} = Runner.run("run_analysis", params, %{actor: "alice"})

            {:ok, general_response} =
              Runner.run("run_analysis", params, %{active_app: "general", actor: "alice"})

            {:ok, job} =
              Jobs.create_job(%{
                name: "missing app scope stocksage action",
                target_type: "registered_action",
                target: %{
                  action_name: "run_analysis",
                  params: Map.new(params, fn {key, value} -> {Atom.to_string(key), value} end)
                },
                schedule: %{kind: "manual"},
                user_id: "alice"
              })

            {:ok, %{run: run, response: job_response}} = JobsRunner.run_now(job)

            %{
              decision:
                if(
                  missing_response.status == :denied and general_response.status == :denied and
                    job_response.status == :denied,
                  do: :denied,
                  else: :allowed
                ),
              result: %{
                missing_response: missing_response,
                general_response: general_response,
                job_response: job_response,
                job_run_status: run.status
              },
              trace: %{
                fixture_id: fixture.id,
                boundary: :runner_app_scope,
                missing_error: missing_response.error,
                general_error: general_response.error,
                job_error: job_response.error,
                job_run_status: run.status,
                confirmations_created: Confirmations.list(status: :pending) |> length()
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert eval.result.missing_response.error == {:app_scope_denied, :missing_active_app_scope}
    assert eval.result.general_response.error == {:app_scope_denied, :missing_active_app_scope}
    assert eval.result.job_response.error == {:app_scope_denied, :missing_active_app_scope}
    assert eval.result.job_run_status == "failed"
    assert eval.trace.confirmations_created == 0
  end

  test "app-handoff-bypass-001: neutral app intent reaches StockSage confirmation gate" do
    fixture = EvalInventory.row!("app-handoff-bypass-001")

    assert {:ok, _setting} =
             Settings.put("workspace.signal_bridge.log_dropped_fragments", false, %{
               audit?: false
             })

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            before_count = Confirmations.list(status: :pending) |> length()

            {:ok, response} =
              IntentAgent.respond(%{
                text: "analyze AAPL",
                user_id: "alice",
                operator_id: "alice",
                thread_id: "thr-handoff-bypass",
                session_id: "sess-handoff-bypass",
                active_app: :allbert
              })

            after_count = Confirmations.list(status: :pending) |> length()

            %{
              decision:
                if(
                  response.status == :needs_confirmation and
                    response.decision.intent == :registry_action and
                    response.decision.selected_action == "run_analysis" and
                    after_count == before_count + 1,
                  do: :needs_confirmation,
                  else: :allowed
                ),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                boundary: :approval_gate,
                confirmations_before: before_count,
                confirmations_after: after_count,
                selected_action: response.decision.selected_action,
                intent: response.decision.intent
              }
            }
          end
        })
      )

    assert_needs_confirmation(eval)
    assert eval.result.approval_handoff.target_action.action["name"] == "run_analysis"
    assert eval.trace.confirmations_after == eval.trace.confirmations_before + 1
  end

  test "StockSage-scoped registered action jobs reach normal confirmation" do
    put_setting!("stocksage.native_engine_enabled", true)
    put_setting!("permissions.stocksage_analyze", "needs_confirmation")

    params = %{
      "ticker" => "AAPL",
      "analysis_date" => "2026-05-22",
      "user_id" => "alice",
      "force_stub" => true
    }

    assert {:ok, job} =
             Jobs.create_job(%{
               name: "stocksage scoped analysis job",
               target_type: "registered_action",
               target: %{action_name: "run_analysis", params: params},
               schedule: %{kind: "manual"},
               user_id: "alice",
               app_id: "stocksage"
             })

    assert {:ok, %{run: run, response: response}} = JobsRunner.run_now(job)

    assert response.status == :needs_confirmation
    assert run.status == "needs_confirmation"
    assert run.action_log["runner_metadata"]["action_name"] == "run_analysis"
    refute Map.get(response, :error) == {:app_scope_denied, :missing_active_app_scope}
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

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "security_eval", audit?: false}) do
      {:ok, _setting} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
