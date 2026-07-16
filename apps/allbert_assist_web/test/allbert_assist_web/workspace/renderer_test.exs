defmodule AllbertAssistWeb.Workspace.RendererTest do
  use AllbertAssistWeb.ConnCase, async: false, lane: :external_runtime_serial

  import Phoenix.LiveViewTest

  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Catalog, as: SurfaceCatalog
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Components.Placeholder
  alias AllbertAssistWeb.Workspace.Renderer

  @stocksage_card_components [
    :analysis_card,
    :agent_report_card,
    :parity_card,
    :debate_round_card
  ]

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")

    root =
      Path.join(System.tmp_dir!(), "allbert-renderer-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", root)
    System.delete_env("ALLBERT_HOME_DIR")
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)

      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_home_dir,
        do: System.put_env("ALLBERT_HOME_DIR", original_home_dir),
        else: System.delete_env("ALLBERT_HOME_DIR")

      File.rm_rf!(root)
    end)

    :ok
  end

  test "dispatch covers every known catalog component" do
    for component <- Catalog.known_components() do
      assert Renderer.renderer_for(component) != Placeholder
      assert Renderer.renderer_descriptor_for(component) == SurfaceCatalog.renderer_for(component)
    end
  end

  test "every known component renders non-empty output" do
    for component <- Catalog.known_components() do
      html =
        render_component(Renderer,
          id: "renderer-#{component}",
          node: %Node{
            id: "node-#{component}",
            component: component,
            props: sample_props(component)
          },
          renderer_context: renderer_context(),
          workspace_state: workspace_state()
        )

      assert html =~ ~s(data-workspace-component="#{component}")
      refute html =~ "component not implemented"

      if component in @stocksage_card_components do
        assert html =~ ~s(data-stocksage-component="#{component}")
        refute html =~ "v0.26 stub"
        refute html =~ "workspace-card-stub"
        refute html =~ "data-workspace-stocksage-adapter"
      end
    end
  end

  test "unknown components render through the safe fallback" do
    html =
      render_component(Renderer,
        id: "unknown-renderer",
        node: %Node{id: "unknown-node", component: :invented, props: %{}}
      )

    assert Renderer.renderer_for(:invented) == Placeholder
    assert html =~ "invented"
    assert html =~ "unknown workspace component"
    refute html =~ "component not implemented"
  end

  test "skeleton placeholder represents manifest atoms without live panel affordances" do
    html =
      render_component(Renderer,
        id: "skeleton-placeholder-renderer",
        node: %Node{
          id: "skeleton-models-panel",
          component: :skeleton_placeholder,
          props: %{
            represents: :models_panel,
            title: "Models placeholder",
            body: "No provider inventory is loaded."
          }
        },
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="skeleton_placeholder")
    assert html =~ ~s(data-workspace-component="models_panel")
    assert html =~ ~s(data-skeleton-placeholder="true")
    assert html =~ ~s(data-skeleton-represents="models_panel")
    refute html =~ ~s(data-action-source="actions-runner")
    refute html =~ "Recommendation Matrix"
  end

  test "skeleton composition metadata is scoped to preview nodes" do
    props = %{
      skeleton_composition_route: "workspace",
      skeleton_composition_zone: "work_workspace",
      skeleton_composition_component: "chat"
    }

    html =
      render_component(Renderer,
        id: "plain-section-renderer",
        node: %Node{id: "plain-section", component: :section, props: props},
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    refute html =~ "data-skeleton-composition-"

    preview_html =
      render_component(Renderer,
        id: "preview-section-renderer",
        node: %Node{
          id: "preview-section",
          component: :section,
          props: Map.put(props, :skeleton_preview?, true)
        },
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert preview_html =~ ~s(data-skeleton-composition-route="workspace")
    assert preview_html =~ ~s(data-skeleton-composition-zone="work_workspace")
    assert preview_html =~ ~s(data-skeleton-composition-component="chat")
  end

  test "retired utility drawer renderer is inert if rendered" do
    html =
      render_component(Renderer,
        id: "utility-drawer-renderer",
        node: %Node{id: "workspace-utility-drawer", component: :utility_drawer, props: %{}},
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="utility_drawer")
    assert html =~ ~s(data-retired="true")
    assert html =~ "Retired workspace utility drawer"
    refute html =~ ~s(href="/jobs")
    refute html =~ "/objectives/"
    refute html =~ "workspace-utility-link"
    refute html =~ ">Tools<"
  end

  test "table catalog atoms consume the shared pattern contract" do
    # v0.62 M0.1: the drawer half of this test retired with the
    # drawer_shell_* pattern helpers — :utility_drawer is now an inert stub
    # (covered by the dedicated inert test above); the table contract stays.
    table_html =
      render_component(Renderer,
        id: "table-contract-renderer",
        node: %Node{id: "table-contract", component: :table, props: %{title: "Rows"}},
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert_classes(table_html, Patterns.table_list_class())

    assert_attrs(
      table_html,
      Patterns.table_list_attrs(title_id: "workspace-component-title-table-contract")
    )

    row_html =
      render_component(Renderer,
        id: "row-contract-renderer",
        node: %Node{id: "row-contract", component: :row, props: %{body: "Row body"}},
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert_classes(row_html, Patterns.table_row_class())
    assert_attrs(row_html, Patterns.table_row_attrs())

    column_html =
      render_component(Renderer,
        id: "column-contract-renderer",
        node: %Node{id: "column-contract", component: :column, props: %{body: "Column body"}},
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert_classes(column_html, Patterns.table_column_class())
    assert_attrs(column_html, Patterns.table_column_attrs())
  end

  test "tile and ephemeral nodes expose semantic accessibility roles" do
    tile_html =
      render_component(Renderer,
        id: "tile-renderer",
        node: %Node{
          id: "tile-1",
          component: :tile,
          props: %{title: "Decision summary", body: "Pinned result"}
        }
      )

    assert tile_html =~ ~s(role="article")
    assert tile_html =~ ~s(aria-labelledby="workspace-component-title-tile-1")
    assert tile_html =~ ~s(id="workspace-component-title-tile-1")

    ephemeral_html =
      render_component(Renderer,
        id: "ephemeral-renderer",
        node: %Node{
          id: "approval-surface-1",
          component: :ephemeral_surface,
          props: %{title: "Approval surface", body: "Needs confirmation"},
          children: [
            %Node{id: "approval-card-1", component: :approval_card, props: %{title: "Approve"}}
          ]
        }
      )

    assert ephemeral_html =~ ~s(role="dialog")
    assert ephemeral_html =~ ~s(aria-modal="true")
    assert ephemeral_html =~ ~s(phx-hook="FocusTrap")
    assert ephemeral_html =~ ~s(aria-labelledby="workspace-component-title-approval-surface-1")
    assert ephemeral_html =~ ~s(id="workspace-component-title-approval-surface-1")
  end

  test "tile with semantic child card does not expose raw tile body" do
    html =
      render_component(Renderer,
        id: "objective-tile-renderer",
        node: %Node{
          id: "objective-tile",
          component: :tile,
          props: %{
            title: "Objective Progress",
            body: "kind=objective_card",
            tile_kind: "objective_card"
          },
          children: [
            %Node{
              id: "objective-card",
              component: :objective_card,
              props: %{
                title: "Analyze AAPL",
                body: "Complete a StockSage analysis for AAPL."
              }
            }
          ]
        },
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert html =~ "Objective Progress"
    assert html =~ "Analyze AAPL"
    refute html =~ "workspace-tile-readonly"
    refute html =~ "kind=objective_card"
  end

  test "editable text tile keeps only editor body under phx-update ignore" do
    html =
      render_component(Renderer,
        id: "editable-tile-renderer",
        node: %Node{
          id: "canvas-tile-editable",
          component: :tile,
          props: %{
            title: "Notes",
            tile_id: "tile-editable",
            tile_kind: "markdown",
            tile_text: "offline notes",
            editable?: true
          }
        },
        renderer_context:
          Map.merge(renderer_context(), %{
            user_id: "local",
            thread_id: "thread-1",
            workspace_offline_enabled?: true,
            workspace_indexeddb_quota_bytes: 1024
          }),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="tile")
    assert html =~ ~s(id="workspace-tile-editor-tile-editable")
    assert html =~ ~s(phx-hook="WorkspaceTileEditor")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(data-quota-bytes="1024")
    assert html =~ "offline notes"
    assert html =~ ~s(id="workspace-tile-action-tile-editable")
    assert html =~ ~s(phx-click="manage_workspace_tile")
    assert html =~ ~s(phx-value-operation="pin")
    assert html =~ ~s(id="workspace-tile-menu-button-tile-editable")
    refute html =~ ~s(id="workspace-tile-action-tile-editable" disabled)
  end

  test "tile renderer opens operator action menu from renderer context" do
    html =
      render_component(Renderer,
        id: "tile-menu-renderer",
        node: %Node{
          id: "canvas-tile-menu",
          component: :tile,
          props: %{
            title: "Analysis",
            body: "kind=analysis_card",
            tile_id: "tile-menu",
            tile_kind: "analysis_card",
            pinned?: true
          }
        },
        renderer_context:
          Map.merge(renderer_context(), %{
            open_tile_menu_id: "tile-menu"
          }),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(id="workspace-tile-menu-tile-menu")
    assert html =~ ~s(role="menu")
    assert html =~ ~s(id="workspace-tile-inspect-tile-menu")
    assert html =~ ~s(phx-click="open_tile_inspector")
    assert html =~ "Unpin tile"
    assert html =~ "Inspect"
    assert html =~ "Remove tile"
    assert html =~ ~s(phx-value-operation="remove")
  end

  test "tile renderer exposes offline conflict revert affordance" do
    html =
      render_component(Renderer,
        id: "conflict-tile-renderer",
        node: %Node{
          id: "canvas-tile-conflict",
          component: :tile,
          props: %{
            title: "Notes",
            tile_id: "tile-conflict",
            tile_kind: "text",
            tile_text: "stale offline notes",
            editable?: true,
            conflict_summary: %{
              conflict?: true,
              conflict_count: 2,
              revert_revision_id: "rev-before-conflict"
            }
          }
        },
        renderer_context:
          Map.merge(renderer_context(), %{
            user_id: "local",
            thread_id: "thread-1",
            workspace_offline_enabled?: true
          }),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-conflict-banner="true")
    assert html =~ "2 offline edit(s) were merged"
    assert html =~ ~s(phx-click="revert_tile_revision")
    assert html =~ ~s(phx-value-revision-id="rev-before-conflict")
  end

  test "tabs render accessible tablist, tabs, and panels" do
    html =
      render_component(Renderer,
        id: "tabs-renderer",
        node: %Node{
          id: "tabs-1",
          component: :tabs,
          props: %{title: "Inspector tabs"},
          children: [
            %Node{
              id: "tab-overview",
              component: :tab,
              props: %{
                title: "Overview",
                selected?: true,
                panel_id: "workspace-component-panel-overview"
              }
            },
            %Node{
              id: "panel-overview",
              component: :tab_panel,
              props: %{title: "Overview panel", tab_id: "workspace-component-tab-overview"}
            }
          ]
        },
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(role="tablist")
    assert html =~ ~s(phx-hook="WorkspaceTabs")
    assert html =~ ~s(role="tab")
    assert html =~ ~s(aria-selected="true")
    assert html =~ ~s(role="tabpanel")
  end

  test "M10 intents panel renders v0.56 action DTOs and gated affordances" do
    {:ok, _path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show app",
        examples: ["show app"],
        synonyms: ["app details"],
        required_slots: []
      })

    html =
      render_component(Renderer,
        id: "intents-panel-renderer",
        node: %Node{
          id: "intents-panel",
          component: :intents_panel,
          props: %{title: "Intents"}
        },
        renderer_context: Map.put(renderer_context(), :canvas_destination, "workspace:intents"),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="intents_panel")
    assert html =~ ~s(data-action-source="actions-runner")
    assert html =~ "Coverage"
    assert html =~ "Eval Gate"
    assert html =~ ~s(id="workspace-intent-promote-show_app")
    assert html =~ ~s(phx-value-operator-action="promote")
    assert html =~ ~s(id="workspace-intent-edit-append_memory")
    assert html =~ ~s(phx-value-operator-action="edit")
    refute html =~ "sk-"
    refute html =~ "api_key"
    refute html =~ "secret://"
  end

  test "M10 models panel renders recommendation DTOs behind a bounded inventory affordance" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "nomic-embed-text", "context_length" => 2048},
          %{"model" => "llama3.1:8b", "context_length" => 128_000}
        ]
      })
    end)

    html =
      render_component(Renderer,
        id: "models-panel-renderer",
        node: %Node{
          id: "models-panel",
          component: :models_panel,
          props: %{title: "Models"}
        },
        renderer_context:
          renderer_context()
          |> Map.put(:canvas_destination, "workspace:models")
          |> Map.put(:req_options, plug: {Req.Test, __MODULE__}),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="models_panel")
    assert html =~ ~s(data-action-source="actions-runner")
    assert html =~ "Recommendation Matrix"
    assert html =~ ~s(id="workspace-models-inventory-toggle")
    assert html =~ "Show Rows"
    refute html =~ "secret://"
    refute html =~ "api_key"
    refute html =~ "sk-"
    refute html =~ "http://"
  end

  test "M11 surface policy panel renders editable Settings Central DTO rows" do
    html =
      render_component(Renderer,
        id: "surface-policy-panel-renderer",
        node: %Node{
          id: "surface-policy-panel",
          component: :surface_policy_panel,
          props: %{title: "Surface Policy"}
        },
        renderer_context:
          Map.put(renderer_context(), :canvas_destination, "workspace:surface_policy"),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="surface_policy_panel")
    assert html =~ ~s(data-action-source="actions-runner")
    assert html =~ "Default Policy"
    assert html =~ "Render assistant summary"
    assert html =~ "Configured Rows"
    assert html =~ "cli / list_settings"
    assert html =~ ~s(phx-click="set_surface_policy_mode")
    assert html =~ "Use Summary"
    refute html =~ "secret://"
    refute html =~ "api_key"
  end

  defp sample_props(:header), do: %{title: "Workspace Header", subtitle: "Subheading"}
  defp sample_props(:empty_state), do: %{title: "Empty", body: "Nothing to render yet."}
  defp sample_props(:link), do: %{label: "Open trace", body: "/trace/example"}
  defp sample_props(:status_badge), do: %{label: "Status", value: "ready"}

  defp sample_props(:analysis_card) do
    %{
      title: "AAPL analysis completed",
      ticker: "AAPL",
      engine: "native",
      rating: "Overweight",
      confidence: 0.82,
      status: "completed",
      summary: "Constructive setup.",
      analysis_id: "ana_renderer"
    }
  end

  defp sample_props(:agent_report_card) do
    %{
      agent: "stocksage.market_context",
      role: "analyst",
      rating: "Hold",
      confidence: 0.7,
      status: "completed",
      summary: "Market context is mixed.",
      key_points: ["Momentum improving"]
    }
  end

  defp sample_props(:parity_card) do
    %{
      native_rating: "Overweight",
      python_rating: "Overweight",
      rating_agreement: "exact",
      confidence_delta: 0.04,
      parity_pass: true,
      status: "completed",
      summary: "Native and Python agree."
    }
  end

  defp sample_props(:debate_round_card) do
    %{
      round: 1,
      side: "bull",
      agent: "bull_thesis",
      rating: "Buy",
      status: "completed",
      summary: "Bull case leads.",
      counterpoints: ["Valuation risk"]
    }
  end

  defp sample_props(_component), do: %{title: "Renderer sample", body: "Rendered output"}

  defp renderer_context do
    %{
      active_objectives: [%{id: "obj-1", status: "running", title: "Sample objective"}],
      canvas_tiles: [%{id: "tile-1"}],
      ephemeral_surfaces: [%{id: "surface-1"}]
    }
  end

  defp workspace_state do
    %{
      prompt: "Hello Allbert",
      response: nil,
      asking?: false,
      approval_lines: []
    }
  end

  defp assert_classes(html, classes) do
    classes
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn class -> assert html =~ class end)
  end

  defp assert_attrs(html, attrs) do
    Enum.each(attrs, fn
      {key, true} -> assert html =~ ~s(#{key})
      {key, value} -> assert html =~ ~s(#{key}="#{value}")
    end)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
