defmodule AllbertAssist.Security.TemplateCreationEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Templates
  alias AllbertAssist.Templates.Scaffold

  @v038_eval_ids [
    "template-create-disabled-001",
    "template-param-injection-001",
    "template-path-traversal-001",
    "template-overwrite-deny-001",
    "template-authority-bypass-001",
    "template-integration-gate-001",
    "template-canvas-authority-001",
    "template-scheduled-flow-escalation-001",
    "template-unsupported-live-target-001"
  ]

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "v0.38 template eval rows are registered in the inventory" do
    assert @v038_eval_ids ==
             :v038
             |> EvalInventory.rows_for_milestone()
             |> Enum.map(& &1.id)
  end

  test "template creation evals deny disabled, unsafe, and destructive writes", %{home: home} do
    disabled =
      run_eval(
        fixture("template-create-disabled-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "create_from_template",
                %{pattern_id: "llm_tool", params: %{"name" => "Disabled Tool"}},
                context()
              )

            draft_root = Path.join([home, "dynamic_plugins", "drafts", "disabled_tool"])

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                error: response.error,
                draft_written?: File.exists?(draft_root)
              }
            }
          end
        })
      )

    assert_denied(disabled)
    assert disabled.trace.error == :template_create_disabled
    refute disabled.trace.draft_written?

    injection =
      run_eval(
        fixture("template-param-injection-001", %{
          run: fn fixture ->
            malicious_instruction =
              ~S|"; System.cmd("touch", ["/tmp/template-param-injection"]); #|

            malicious_literal = ~S|";System.cmd("id",[]);#|

            {:ok, tool_rendered} =
              Templates.render("llm_tool", %{
                "name" => "Injected Tool",
                "description" => "Attempt to inject executable code.",
                "instruction" => malicious_instruction,
                "permission" => "read_only"
              })

            {:ok, plugin_rendered} =
              Templates.render("plugin", %{
                "name" => "Injected Plugin",
                "version" => malicious_literal
              })

            {:ok, app_rendered} =
              Templates.render("app", %{
                "name" => "Injected App",
                "version" => malicious_literal
              })

            {:ok, flow_rendered} =
              Templates.render("flow", %{
                "name" => "Injected Flow",
                "timezone" => malicious_literal
              })

            rendered_sources = [
              {"tool instruction", rendered_source!(tool_rendered, "source/lib/action.ex")},
              {"plugin version",
               rendered_source!(plugin_rendered, "lib/injected_plugin/plugin.ex")},
              {"app plugin version",
               rendered_source!(app_rendered, "lib/injected_app/plugin.ex")},
              {"app module version", rendered_source!(app_rendered, "lib/injected_app/app.ex")},
              {"flow timezone", rendered_source!(flow_rendered, "lib/injected_flow/flow.ex")}
            ]

            unsafe_sources =
              Enum.filter(rendered_sources, fn {_label, source} ->
                unsafe_elixir_source?(source)
              end)

            %{
              decision: if(unsafe_sources == [], do: :denied, else: :allowed),
              result: %{source_labels: Enum.map(rendered_sources, &elem(&1, 0))},
              trace: %{
                fixture_id: fixture.id,
                params_are_data?: unsafe_sources == [],
                unsafe_sources: Enum.map(unsafe_sources, &elem(&1, 0))
              }
            }
          end
        })
      )

    assert_denied(injection)
    assert injection.trace.params_are_data?

    traversal =
      run_eval_result("template-path-traversal-001", fn ->
        Scaffold.preview("plugin", %{"name" => "Traversal Plugin"}, target: "../outside")
      end)

    assert_denied(traversal)
    assert {:unsafe_target_root, "../outside"} = traversal.result

    enable_template_create!()
    existing_target = Path.join(home, "existing-plugin")
    File.mkdir_p!(existing_target)
    File.write!(Path.join(existing_target, "KEEP"), "operator content")

    overwrite =
      run_eval(
        fixture("template-overwrite-deny-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "scaffold_template",
                %{
                  pattern_id: "plugin",
                  params: %{"name" => "Existing Plugin"},
                  target: existing_target
                },
                context()
              )

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                error: response.error,
                keep_file: File.read!(Path.join(existing_target, "KEEP")),
                manifest_written?: File.exists?(Path.join(existing_target, "allbert_plugin.json"))
              }
            }
          end
        })
      )

    assert_denied(overwrite)
    assert {:target_exists, _preview} = overwrite.trace.error
    assert overwrite.trace.keep_file == "operator content"
    refute overwrite.trace.manifest_written?
  end

  test "template authority evals keep scaffolds and drafts non-authoritative", %{home: home} do
    enable_template_create!()

    target = Path.join(home, "authority-tool")

    authority =
      run_eval(
        fixture("template-authority-bypass-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "scaffold_template",
                %{
                  pattern_id: "llm_tool",
                  params: %{
                    "name" => "Authority Tool",
                    "permission" => "external_network"
                  },
                  target: target
                },
                context()
              )

            action_name = "template_authority_tool"
            registered? = match?({:ok, _capability}, Registry.capability(action_name))
            draft_written? = File.exists?(MetadataStore.draft_root("authority_tool"))

            %{
              decision:
                if(response.status == :completed and not registered? and not draft_written?,
                  do: :denied,
                  else: :allowed
                ),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                scaffold_status: response.status,
                action_registered?: registered?,
                draft_written?: draft_written?
              }
            }
          end
        })
      )

    assert_denied(authority)
    assert authority.trace.scaffold_status == :completed
    refute authority.trace.action_registered?
    refute authority.trace.draft_written?

    enable_live_template_stack!()

    gate =
      run_eval(
        fixture("template-integration-gate-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "create_from_template",
                %{
                  pattern_id: "llm_tool",
                  mode: "live_integration",
                  params: %{"name" => "Gate Tool", "permission" => "read_only"}
                },
                context()
              )

            {:ok, draft} = DynamicPlugins.get_draft("gate_tool")

            action_registered? =
              match?({:ok, _capability}, Registry.capability("template_gate_tool"))

            %{
              decision:
                if(
                  response.status == :completed and draft.gate["status"] == "not_run" and
                    not action_registered?,
                  do: :denied,
                  else: :allowed
                ),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                draft_tier: draft.tier,
                gate_status: draft.gate["status"],
                next_actions: Enum.map(response.next_actions, & &1.name),
                action_registered?: action_registered?
              }
            }
          end
        })
      )

    assert_denied(gate)
    assert gate.trace.draft_tier == "draft"
    assert gate.trace.gate_status == "not_run"

    assert gate.trace.next_actions == [
             "run_dynamic_draft_trial",
             "run_dynamic_draft_gate",
             "integrate_dynamic_draft"
           ]

    refute gate.trace.action_registered?

    assert {:ok, _setting} =
             Settings.put("permissions.dynamic_codegen_request", "denied", %{audit?: false})

    canvas =
      run_eval(
        fixture("template-canvas-authority-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "create_from_template",
                %{
                  pattern_id: "llm_tool",
                  mode: "live_integration",
                  params: %{"name" => "Canvas Denied Tool", "permission" => "read_only"}
                },
                context(%{surface: "/workspace", canvas_destination: "workspace:create"})
              )

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                permission: response.permission_decision.permission,
                decision: response.permission_decision.decision,
                draft_written?: File.exists?(MetadataStore.draft_root("canvas_denied_tool"))
              }
            }
          end
        })
      )

    assert_denied(canvas)
    assert canvas.trace.permission == :dynamic_codegen_request
    refute canvas.trace.draft_written?
  end

  test "flow and unsupported live-target evals fail closed", %{home: home} do
    enable_template_create!()

    flow_target = Path.join(home, "scheduled-flow")

    scheduled =
      run_eval(
        fixture("template-scheduled-flow-escalation-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "scaffold_template",
                %{
                  pattern_id: "flow",
                  params: %{
                    "name" => "Morning Brief",
                    "schedule" => "daily",
                    "at" => "08:00"
                  },
                  target: flow_target
                },
                context()
              )

            blueprint = File.read!(Path.join(flow_target, "priv/jobs/morning_brief.json"))
            enabled? = blueprint =~ ~s("enabled": true)
            draft_written? = File.exists?(MetadataStore.draft_root("morning_brief"))

            %{
              decision:
                if(response.status == :completed and not enabled? and not draft_written?,
                  do: :denied,
                  else: :allowed
                ),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                scaffold_status: response.status,
                job_enabled?: enabled?,
                draft_written?: draft_written?
              }
            }
          end
        })
      )

    assert_denied(scheduled)
    assert scheduled.trace.scaffold_status == :completed
    refute scheduled.trace.job_enabled?
    refute scheduled.trace.draft_written?

    enable_live_template_stack!()

    unsupported =
      run_eval(
        fixture("template-unsupported-live-target-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "create_from_template",
                %{
                  pattern_id: "plugin",
                  mode: "live_integration",
                  params: %{"name" => "Plugin Live"}
                },
                context()
              )

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                error: response.error,
                draft_written?: File.exists?(MetadataStore.draft_root("plugin_live"))
              }
            }
          end
        })
      )

    assert_denied(unsupported)
    assert unsupported.trace.error == {:unsupported_live_integration_pattern, "plugin"}
    refute unsupported.trace.draft_written?
  end

  defp run_eval_result(id, fun) do
    run_eval(
      fixture(id, %{
        run: fn fixture ->
          result = fun.()

          %{
            decision: decision_for_error(result),
            result: result_value(result),
            trace: %{fixture_id: fixture.id}
          }
        end
      })
    )
  end

  defp decision_for_error({:error, _reason}), do: :denied
  defp decision_for_error({:ok, _result}), do: :allowed
  defp decision_for_error(_result), do: :error

  defp result_value({:error, reason}), do: reason
  defp result_value({:ok, result}), do: result
  defp result_value(result), do: result

  defp fixture(id, attrs) do
    id
    |> EvalInventory.row!()
    |> Map.merge(attrs)
  end

  defp rendered_source!(rendered, path) do
    rendered.files
    |> Enum.find(&(&1.path == path))
    |> Map.fetch!(:content)
  end

  defp unsafe_elixir_source?(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> system_cmd_call?(ast)
      {:error, _reason} -> true
    end
  end

  defp system_cmd_call?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, _args} = node, _found? ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp enable_template_create! do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
  end

  defp enable_dynamic_codegen! do
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})
  end

  defp enable_dynamic_live_loader! do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.live_loader_enabled", true, %{audit?: false})
  end

  defp enable_sandbox_elixir! do
    assert {:ok, _setting} = Settings.put("sandbox.elixir.enabled", true, %{audit?: false})
  end

  defp enable_live_template_stack! do
    enable_dynamic_codegen!()
    enable_dynamic_live_loader!()
    enable_sandbox_elixir!()
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        actor: "local",
        operator_id: "local",
        channel: :live_view,
        surface: "/workspace"
      },
      overrides
    )
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-template-creation-eval-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
