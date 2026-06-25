defmodule AllbertAssist.Security.V058SurfaceConsistencyEvalTest do
  @moduledoc """
  v0.58 surface consistency, settings enforcement, web design-system, operator-panel,
  surface-policy, and helper-consolidation release eval inventory checks.
  """
  use AllbertAssist.SecurityEvalCase, async: true

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Repo
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.EventRecorder
  alias AllbertAssist.Surface.Renderer

  setup {Req.Test, :verify_on_exit!}

  @m131c_operator_reads ~w(
    intent_coverage
    intent_list_descriptors
    intent_list_review
    model_doctor
  )

  @eval_groups [
    surface_consistency: ~w(
      surface-renderer-unified-parity-001
      surface-event-audit-parity-001
      web-reads-action-backed-001
      web-identity-resolved-001
      surface-invocation-shared-001
    ),
    settings_enforcement: ~w(
      settings-no-bypass-001
    ),
    web_design_system: ~w(
      design-tokens-global-001
      component-variant-registry-001
      pattern-library-a11y-001
      all-pages-catalog-shell-001
      chat-primary-default-001
      ephemeral-renders-as-modal-dialog-001
      conversations-relabel-ui-only-001
      workspace-shell-validates-against-catalog-001
      fragment-emission-hmac-validated-001
      launcher-selection-view-only-001
      mobile-single-column-and-reduced-motion-001
    ),
    operator_panel_surface_policy: ~w(
      intents-panel-v056-dto-parity-001
      intents-panel-gated-promotion-001
      models-panel-v056-dto-redaction-001
      surface-policy-raw-report-affordance-001
      surface-policy-settings-central-001
      surface-policy-no-authority-grant-001
    ),
    redundancy: ~w(
      redundancy-consolidation-no-regression-001
    )
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  test "v0.58 eval inventory rows are complete and grouped by implemented surface" do
    rows = EvalInventory.rows_for_milestone(:v058)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v058))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))

    assert_eval_group!(:surface_consistency, :surface_consistency)
    assert_eval_group!(:settings_enforcement, :settings_enforcement)
    assert_eval_group!(:web_design_system, :web_design_system)
    assert_eval_group!(:operator_panel_surface_policy, :surface_policy)
    assert_eval_group!(:redundancy, :redundancy_consolidation)
  end

  test "v0.58 release eval rows encode both positive conformance and denied bypass cases" do
    rows = EvalInventory.rows_for_milestone(:v058)

    assert Enum.any?(rows, &(&1.expected == :allowed))
    assert Enum.any?(rows, &(&1.expected == :denied))

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert row.assert != []
      assert row.scenario =~ ~r/\w/
    end
  end

  test "M13.1C renderer and rejection audit behaviors are asserted, not inventory-only" do
    {:ok, rendered} =
      Renderer.render_response(
        %{
          status: :completed,
          message: "secret://providers/openai/api_key http://127.0.0.1:11434",
          surface_payload: "redacted operator surface payload"
        },
        %{payload: :surface_payload}
      )

    assert rendered.text == "redacted operator surface payload"
    refute rendered.text =~ "secret://"
    refute rendered.text =~ "http://"

    external_event_id = "v058-m131c-#{System.unique_integer([:positive])}"

    assert %Event{} =
             EventRecorder.record_rejection(:mcp_stdio, %{
               external_event_id: external_event_id,
               external_user_id: "fixture-client",
               user_id: "public-protocol:fixture-client",
               reason: "resource_not_exposed",
               payload_summary: "resources/read allbert-memory://missing/namespace"
             })

    assert %Event{
             channel: "mcp_stdio",
             status: "rejected",
             reason: "resource_not_exposed",
             external_user_id: "fixture-client",
             user_id: "public-protocol:fixture-client"
           } = Repo.get_by(Event, external_event_id: external_event_id)
  end

  test "M13.1C profile inventories are source-redacted before actions render them" do
    assert {:ok, providers} = Settings.list_provider_profiles()
    assert {:ok, models} = Settings.list_model_profiles()

    assert providers != []
    assert models != []

    refute Enum.any?(providers, &Map.has_key?(&1, :base_url))
    refute Enum.any?(providers, &Map.has_key?(&1, :api_key_ref))
    refute Enum.any?(models, &Map.has_key?(&1, :provider_base_url))
    refute Enum.any?(models, &Map.has_key?(&1, :provider_api_key_ref))

    refute inspect(providers) =~ "secret://"
    refute inspect(models) =~ "secret://"
  end

  test "M13.1C operator-panel reads consult surface policy without gaining authority" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"models" => []})
    end)

    for action_name <- @m131c_operator_reads do
      assert {:ok, capability} = Registry.capability(action_name)
      assert capability.exposure == :internal
      assert capability.permission == :read_only
      assert capability.confirmation == :not_required
      refute action_name in agent_action_names

      assert {:ok, summary} =
               Runner.run(
                 action_name,
                 %{render_mode: "operator_report", surface: "live_view"},
                 operator_context()
               )

      assert action_render_mode(summary) == :assistant_summary

      assert {:ok, report} =
               Runner.run(action_name, operator_report_params(), operator_context())

      assert action_render_mode(report) == :operator_report
    end
  end

  defp assert_eval_group!(group, surface) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v058)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.surface == surface))
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.58 eval row #{id}")
  end

  defp action_render_mode(%{actions: [action | _actions]}), do: Map.fetch!(action, :render_mode)

  defp operator_context do
    %{
      actor: "local",
      operator_id: "local",
      channel: :live_view,
      surface: "live_view",
      req_options: [plug: {Req.Test, __MODULE__}],
      request: %{operator_id: "local", channel: :live_view}
    }
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface: "live_view", surface_policy_affordance: true}
  end
end
