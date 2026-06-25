defmodule AllbertAssist.Actions.SurfacePolicy.Read do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "surface_policy_read",
    description: "Read the redacted surface policy DTO.",
    category: "settings",
    tags: ["settings", "surface_policy", "read_only", "operator"],
    schema: [
      surface: [type: :string, required: false],
      action: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      surface_policy: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      with {:ok, policy} <- SurfacePolicy.dto(params, context) do
        {:ok,
         %{
           message: message(policy),
           model_payload: "Surface policy report.",
           surface_payload: message(policy),
           status: :completed,
           permission_decision: permission_decision,
           surface_policy: policy,
           actions: [
             Support.action(name(), :completed, permission_decision, %{
               surface_policy: %{
                 surface_count:
                   policy.surfaces |> Enum.map(& &1.surface) |> Enum.uniq() |> length()
               }
             })
           ]
         }}
      end
    end)
  end

  defp message(policy) do
    effective = policy.effective

    if effective do
      "surface policy #{effective.surface}/#{effective.action_name}: render_mode=#{effective.render_mode} max_rows=#{effective.max_rows} redaction=#{effective.redaction_profile}"
    else
      "surface policy rows=#{length(policy.surfaces)} default_render_mode=#{policy.defaults.render_mode}"
    end
  end
end
