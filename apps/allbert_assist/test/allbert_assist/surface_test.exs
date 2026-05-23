defmodule AllbertAssist.SurfaceTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.ActionBinding
  alias AllbertAssist.Surface.Encoder
  alias AllbertAssist.Surface.Node
  alias StockSage.Actions.ListAnalyses

  defp valid_surface(attrs \\ %{}) do
    struct!(
      Surface,
      Map.merge(
        %{
          id: :agent,
          app_id: :allbert,
          label: "Allbert Chat",
          path: "/workspace",
          kind: :chat,
          status: :available,
          fallback_text: "Allbert chat is available at /workspace.",
          nodes: [
            %Node{
              id: "chat-root",
              component: :chat,
              children: [
                %Node{id: "chat-timeline", component: :timeline},
                %Node{id: "chat-composer", component: :composer}
              ]
            }
          ]
        },
        attrs
      )
    )
  end

  defp valid_panel(attrs \\ %{}) do
    struct!(
      Surface,
      Map.merge(
        %{
          id: :fixture_panel,
          app_id: :allbert,
          label: "Fixture Panel",
          path: "/workspace",
          kind: :panel,
          zone: :canvas_panels,
          status: :available,
          fallback_text: "Fixture panel is available in the workspace.",
          metadata: %{visible_when: :active_app, order: 10},
          nodes: [
            %Node{
              id: "fixture-panel-root",
              component: :panel,
              props: %{title: "Fixture panel"},
              children: [%Node{id: "fixture-panel-body", component: :text, props: %{body: "ok"}}]
            }
          ]
        },
        attrs
      )
    )
  end

  test "valid chat surface validates" do
    assert {:ok, %Surface{id: :agent}} = Surface.validate_surface(valid_surface())
  end

  test "valid panel surface validates with a known workspace zone" do
    assert {:ok, %Surface{id: :fixture_panel, zone: :canvas_panels, kind: :panel}} =
             Surface.validate_surface(valid_panel())

    assert {:ok, %Surface{zone: :utility_drawer}} =
             Surface.validate_surface(
               valid_panel(%{
                 id: :metadata_zone_panel,
                 zone: nil,
                 metadata: %{zone: "utility_drawer", visible_when: "operator_opened"}
               })
             )
  end

  test "known components include the v0.32 workspace catalog" do
    assert Surface.known_components() |> length() == 49
    assert :chat in Surface.known_components()
    assert :route in Surface.known_components()
    assert :action_button in Surface.known_components()
    assert :workspace_shell in Surface.known_components()
    assert :app_launcher in Surface.known_components()
    assert :utility_drawer in Surface.known_components()
    assert :settings_panel in Surface.known_components()
    assert :workspace in Surface.known_components()
    assert :canvas in Surface.known_components()
    assert :approval_card in Surface.known_components()
    assert :debate_round_card in Surface.known_components()
  end

  test "rejects invalid panel zones and panel roots" do
    for attrs <- [
          %{zone: :unknown_zone},
          %{zone: nil, metadata: %{}},
          %{nodes: [%Node{id: "not-panel", component: :section}]},
          %{metadata: %{visible_when: :after_midnight}},
          %{metadata: %{order: -1}}
        ] do
      assert {:error, diagnostics} = Surface.validate_surface(valid_panel(attrs))
      assert diagnostics != []
    end

    assert {:error, diagnostics} =
             Surface.validate_surface(valid_surface(%{kind: :chat, zone: :canvas_panels}))

    assert Enum.any?(diagnostics, &(&1.kind == :unexpected_zone))
  end

  test "rejects unknown component and duplicate node ids" do
    assert {:error, diagnostics} =
             Surface.validate_surface(
               valid_surface(%{
                 nodes: [
                   %Node{id: "dup", component: :chat},
                   %Node{id: "dup", component: :unknown}
                 ]
               })
             )

    assert Enum.any?(diagnostics, &(&1.kind == :duplicate_node_id))
    assert Enum.any?(diagnostics, &(&1.kind == :invalid_field))
  end

  test "rejects non-local paths" do
    assert {:error, diagnostics} =
             Surface.validate_surface(valid_surface(%{path: "https://example.com"}))

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_path))

    assert {:error, diagnostics} =
             Surface.validate_surface(valid_surface(%{path: "no-leading-slash"}))

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_path))
  end

  test "rejects secret-like keys and unsafe prop values" do
    unsafe_values = [
      %{api_key: "secret"},
      %{bot_token: "secret"},
      %{body: "<div>html</div>"},
      %{href: "javascript:alert(1)"},
      %{href: "http://example.com"}
    ]

    Enum.each(unsafe_values, fn props ->
      assert {:error, diagnostics} =
               Surface.validate_surface(
                 valid_surface(%{nodes: [%Node{id: "node", component: :text, props: props}]})
               )

      assert diagnostics != []
    end)
  end

  test "valid action binding is enriched with registry metadata" do
    assert {:ok, %Surface{nodes: [%Node{bindings: [binding]}]}} =
             Surface.validate_surface(
               valid_surface(%{
                 nodes: [
                   %Node{
                     id: "action",
                     component: :action_button,
                     bindings: [%ActionBinding{action_name: DirectAnswer.name()}]
                   }
                 ]
               })
             )

    assert binding.action_module == DirectAnswer
    assert binding.permission == :read_only
    assert binding.confirmation_required? == false
  end

  test "invalid action bindings are rejected" do
    for action_name <- ["", "model_invented_action"] do
      assert {:error, diagnostics} =
               Surface.validate_surface(
                 valid_surface(%{
                   nodes: [
                     %Node{
                       id: "action",
                       component: :action_button,
                       bindings: [%ActionBinding{action_name: action_name}]
                     }
                   ]
                 })
               )

      assert diagnostics != []
    end
  end

  test "panel action bindings cannot target another app action" do
    assert {:error, diagnostics} =
             Surface.validate_surface(
               valid_panel(%{
                 app_id: :allbert,
                 nodes: [
                   %Node{
                     id: "foreign-action",
                     component: :panel,
                     children: [
                       %Node{
                         id: "foreign-action-button",
                         component: :action_button,
                         bindings: [%ActionBinding{action_name: ListAnalyses.name()}]
                       }
                     ]
                   }
                 ]
               })
             )

    assert Enum.any?(diagnostics, &(&1.kind == :foreign_action_binding))
  end

  test "catalog validation and A2UI stub" do
    assert {:ok, [%{component: :chat}]} =
             Surface.validate_catalog([
               %{component: :chat, allowed_props: [], allowed_bindings: []}
             ])

    assert {:error, diagnostics} = Surface.validate_catalog([%{component: :nope}])
    assert Enum.any?(diagnostics, &(&1.kind == :invalid_field))

    assert {:error, :not_implemented} = Encoder.to_a2ui(valid_surface())
  end
end
