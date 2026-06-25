defmodule AllbertAssist.Actions.SurfacePolicyActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.SurfacePolicy.Read, as: ReadSurfacePolicy
  alias AllbertAssist.Actions.SurfacePolicy.Update, as: UpdateSurfacePolicy
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.Settings
  alias AllbertAssist.SurfacePolicy

  @m131c_operator_reads ~w(
    intent_coverage
    intent_list_descriptors
    intent_list_review
    model_doctor
  )

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-surface-policy-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "read action returns one redacted policy DTO" do
    assert {:ok, response} =
             ReadSurfacePolicy.run(%{surface: "cli", action: "list_settings"}, %{})

    assert response.status == :completed
    assert response.message =~ "surface policy cli/list_settings"
    assert response.surface_policy.defaults.render_mode == :assistant_summary
    assert response.surface_policy.effective.surface == "cli"
    assert response.surface_policy.effective.action_name == "list_settings"
    assert response.surface_policy.effective.render_mode == :operator_report
    assert response.surface_policy.effective.max_rows == 1000
    assert response.surface_policy.effective.raw_operator_report_allowed?

    assert Enum.any?(response.surface_policy.surfaces, fn row ->
             row.surface == "cli" and row.action_name == "list_settings" and
               row.render_mode == :operator_report
           end)

    refute inspect(response) =~ "secret://"
    refute inspect(response) =~ "api_key"
  end

  test "update action writes through Settings Central and preserves explicit raw affordance" do
    context = %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}}

    assert SurfacePolicy.render_mode("list_settings", %{render_mode: "operator_report"}, %{
             surface: "mcp_http"
           }) == :assistant_summary

    assert {:ok, response} =
             UpdateSurfacePolicy.run(
               %{
                 surface: "mcp_http",
                 action: "list_settings",
                 field: "render_mode",
                 value: "operator_report"
               },
               context
             )

    assert response.status == :completed
    assert response.setting.key == "surface_policy.surfaces.mcp_http.list_settings.render_mode"
    assert {:ok, "operator_report"} = Settings.get(response.setting.key)
    assert %{settings_metadata: %{audit_path: audit_path}} = hd(response.actions)
    assert is_binary(audit_path)
    assert File.exists?(audit_path)

    assert SurfacePolicy.render_mode("list_settings", %{render_mode: "operator_report"}, %{
             surface: "mcp_http"
           }) == :assistant_summary

    assert SurfacePolicy.render_mode(
             "list_settings",
             %{render_mode: "operator_report", surface_policy_affordance: true},
             %{surface: "mcp_http"}
           ) == :operator_report
  end

  test "M13.1C operator-panel reads are policy configured but still require affordance" do
    assert {:ok, response} = ReadSurfacePolicy.run(%{}, %{})

    for action_name <- @m131c_operator_reads do
      assert Enum.any?(response.surface_policy.surfaces, fn row ->
               row.surface == "live_view" and row.action_name == action_name and
                 row.render_mode == :operator_report
             end)

      assert SurfacePolicy.render_mode(action_name, %{render_mode: "operator_report"}, %{
               surface: "live_view"
             }) == :assistant_summary

      assert SurfacePolicy.render_mode(
               action_name,
               %{render_mode: "operator_report", surface_policy_affordance: true},
               %{surface: "live_view"}
             ) == :operator_report
    end
  end

  test "policy rejects invalid values and grants no public authority" do
    context = %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}}

    assert {:ok, denied} =
             UpdateSurfacePolicy.run(
               %{surface: "cli", action: "list_settings", field: "render_mode", value: "raw"},
               context
             )

    assert denied.status == :denied
    assert denied.message =~ "invalid_setting"

    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())
    refute "surface_policy_read" in agent_action_names
    refute "surface_policy_update" in agent_action_names

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools(["surface_policy_read", "surface_policy_update"])

    assert Enum.map(rejected, & &1.reason) == [:not_agent_exposable, :not_agent_exposable]
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
