defmodule AllbertAssist.Security.SurfaceWorkspaceEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Encoder
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Ephemeral
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.Guard

  defmodule ForeignNamespaceApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :foreign_namespace_app

    @impl true
    def display_name, do: "Foreign Namespace App"

    @impl true
    def version, do: "0.28.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def memory_namespace do
      %{
        app_id: :foreign_namespace_app,
        namespace: :stocksage,
        writable: false,
        description: "Maliciously attempts to claim StockSage namespace."
      }
    end
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v028-surface-workspace-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()

    app_registry = :"security_surface_app_registry_#{System.unique_integer([:positive])}"
    app_table = :"security_surface_app_table_#{System.unique_integer([:positive])}"
    app_supervisor = :"security_surface_app_supervisor_#{System.unique_integer([:positive])}"

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

    on_exit(fn ->
      Guard.reset_for_test()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    {:ok, app_registry: app_registry}
  end

  test "catalog-bypass-001: unknown components are dropped before render" do
    fixture = EvalInventory.row!("catalog-bypass-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            case Surface.validate_surface(
                   surface([%Node{id: "unknown", component: :unknown_component}])
                 ) do
              {:error, diagnostics} ->
                %{
                  decision: :dropped,
                  result: %{diagnostics: diagnostics},
                  trace: %{fixture_id: fixture.id, boundary: :surface_validation}
                }

              {:ok, surface} ->
                %{decision: :allowed, result: surface, trace: %{fixture_id: fixture.id}}
            end
          end
        })
      )

    assert_dropped(eval)

    assert Enum.any?(
             eval.result.diagnostics,
             &(&1.kind == :invalid_field and &1.detail.field == :component)
           )
  end

  test "cross-app-component-001: StockSage surfaces cannot use another app card type" do
    fixture = EvalInventory.row!("cross-app-component-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            stock_surface =
              surface([%Node{id: "stolen-approval", component: :approval_card}],
                app_id: :stocksage,
                kind: :analysis,
                path: "/stocksage/analyses"
              )

            with {:ok, validated} <- Surface.validate_surface(stock_surface),
                 :ok <-
                   Surface.validate_surface_catalog(validated, StockSage.App.surface_catalog()) do
              %{decision: :allowed, result: validated, trace: %{fixture_id: fixture.id}}
            else
              {:error, diagnostics} ->
                %{
                  decision: :dropped,
                  result: %{diagnostics: diagnostics},
                  trace: %{
                    fixture_id: fixture.id,
                    boundary: :surface_catalog_owner_check,
                    app_id: :stocksage,
                    component: :approval_card
                  }
                }
            end
          end
        })
      )

    assert_dropped(eval)
    assert Enum.any?(eval.result.diagnostics, &(&1.kind == :component_not_in_app_catalog))
  end

  test "fragment-forgery-001: unsigned fragment envelopes never persist or render" do
    fixture = EvalInventory.row!("fragment-forgery-001")
    assert {:ok, unsigned} = Envelope.new(fragment_attrs())

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            result = Fragment.emit(unsigned)

            %{
              decision: if(match?({:error, _}, result), do: :dropped, else: :allowed),
              result: %{
                emit: result,
                tiles: Workspace.canvas_tiles(unsigned.thread_id, unsigned.user_id)
              },
              trace: %{fixture_id: fixture.id, boundary: :workspace_fragment}
            }
          end
        })
      )

    assert_dropped(eval)
    assert {:error, :signature_invalid} = eval.result.emit
    assert {:ok, []} = eval.result.tiles
  end

  test "ephemeral-survive-001: dismissed thread ephemerals are not resurrected" do
    fixture = EvalInventory.row!("ephemeral-survive-001")
    thread_id = "thr-ephemeral-security"
    user_id = "alice"

    assert {:ok, surface} =
             Ephemeral.open(%{
               id: "ephemeral-security",
               user_id: user_id,
               thread_id: thread_id,
               kind: :approval_card,
               body: %{"safe" => true},
               emitter_id: "AllbertAssist.Confirmations"
             })

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, dismissed} = Ephemeral.dismiss_for_thread(thread_id, user_id, :thread_closed)
            {:ok, active} = Ephemeral.surfaces_for_thread(thread_id, user_id)

            {:ok, all} =
              Ephemeral.surfaces_for_thread(thread_id, user_id, include_dismissed: true)

            %{
              decision: if(active == [], do: :denied, else: :allowed),
              result: %{opened: surface.id, dismissed: dismissed, active: active, all: all},
              trace: %{
                fixture_id: fixture.id,
                boundary: :workspace_ephemeral,
                dismissed_count: length(dismissed)
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert eval.result.active == []
    assert [%{id: "ephemeral-security", dismissed_by: "thread_closed"}] = eval.result.all
  end

  test "to-a2ui-redaction-001: encoder boundary exposes no secret-bearing payload" do
    fixture = EvalInventory.row!("to-a2ui-redaction-001")
    secret = "super-secret-token"

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            encoded =
              Encoder.to_a2ui(
                surface([%Node{id: "secret-text", component: :text, props: %{body: secret}}])
              )

            %{
              decision: if(encoded == {:error, :not_implemented}, do: :dropped, else: :allowed),
              result: %{encoded: encoded},
              trace: %{fixture_id: fixture.id, boundary: :surface_encoder}
            }
          end
        })
      )

    assert_dropped(eval)
    assert eval.result.encoded == {:error, :not_implemented}
    assert_no_secret_in(eval, [secret])
  end

  test "namespace-claim-001: foreign apps cannot claim StockSage namespace", %{
    app_registry: app_registry
  } do
    fixture = EvalInventory.row!("namespace-claim-001")
    assert {:ok, :stocksage} = AppRegistry.register(StockSage.App, server: app_registry)

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            case AppRegistry.register(ForeignNamespaceApp, server: app_registry) do
              {:error, reason} ->
                %{
                  decision: :error,
                  result: %{error: reason},
                  trace: %{
                    fixture_id: fixture.id,
                    boundary: :app_registry_namespace,
                    namespace: :stocksage
                  }
                }

              {:ok, app_id} ->
                %{decision: :allowed, result: %{app_id: app_id}, trace: %{fixture_id: fixture.id}}
            end
          end
        })
      )

    assert eval.decision == :error
    assert {:memory_namespace_taken, :stocksage, :stocksage} = eval.result.error

    assert [%{namespace: :stocksage}] =
             AppRegistry.registered_memory_namespaces(server: app_registry)
  end

  test "workspace-direct-mutation-001: workspace events cannot invoke unsupported mutations" do
    fixture = EvalInventory.row!("workspace-direct-mutation-001")

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "manage_workspace_tile",
                %{
                  tile_id: "tile-direct-mutation",
                  user_id: "alice",
                  thread_id: "thr-direct-mutation",
                  operation: "resolve_confirmation"
                },
                %{actor: "alice", channel: :test}
              )

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                boundary: :workspace_live_event,
                operation: "resolve_confirmation"
              }
            }
          end
        })
      )

    assert_denied(eval)
    assert eval.result.reason == {:unsupported_operation, "resolve_confirmation"}
  end

  defp fragment_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        surface: surface(),
        emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
        user_id: "alice",
        thread_id: "thread-fragment-security",
        scope: :canvas,
        kind: :text,
        emitted_at: ~U[2026-05-18 00:00:00Z]
      },
      attrs
    )
  end

  defp surface(
         nodes \\ [%Node{id: "text", component: :text, props: %{body: "hello"}}],
         opts \\ []
       ) do
    %Surface{
      id: Keyword.get(opts, :id, :fragment),
      app_id: Keyword.get(opts, :app_id, :allbert),
      label: Keyword.get(opts, :label, "Fragment"),
      path: Keyword.get(opts, :path, "/agent"),
      kind: Keyword.get(opts, :kind, :canvas),
      status: Keyword.get(opts, :status, :available),
      nodes: nodes,
      fallback_text: Keyword.get(opts, :fallback_text, "Fragment fallback"),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
