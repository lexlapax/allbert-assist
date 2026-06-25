defmodule AllbertAssist.Actions.Settings.ListModelProfiles do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_model_profiles",
    description: "List model profiles with redacted credential status.",
    category: "settings",
    tags: ["settings", "models", "read_only"],
    schema: [
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    policy = SurfacePolicy.report_policy(name(), params, context)
    {:ok, models} = Settings.list_model_profiles()
    visible_models = bounded(models, policy)

    {:ok,
     %{
       message: message(visible_models, length(models), policy),
       status: PermissionGate.response_status(permission_decision),
       models: visible_models,
       actions: [
         %{
           name: "list_model_profiles",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{
             model_count: length(models),
             rendered_count: length(visible_models),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           }
         }
       ]
     }}
  end

  defp message(models, total_count, %{render_mode: :operator_report}) do
    rendered =
      models
      |> Enum.map(
        &"- #{&1.name}: provider=#{&1.provider}, endpoint_kind=#{&1.provider_endpoint_kind}, model=#{&1.model}, credential=#{&1.credential_status}"
      )
      |> Enum.join("\n")

    suffix =
      if length(models) < total_count do
        "\n\nShowing #{length(models)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "Model profiles:\n\n#{rendered}#{suffix}"
  end

  defp message(_models, total_count, %{render_mode: :assistant_summary}) do
    "Model registry has #{total_count} profiles loaded. I can discuss model setup safely here, " <>
      "but I won't dump the full operator report in chat. Use `/models` for the TUI " <>
      "model doctor or `mix allbert.model list` for the full operator report."
  end

  defp bounded(rows, policy), do: Enum.take(rows, policy.max_rows)
end
