defmodule AllbertAssist.Actions.Settings.ListModelProfiles do
  @moduledoc false

  use Jido.Action,
    name: "list_model_profiles",
    description: "List model profiles with redacted credential status.",
    category: "settings",
    tags: ["settings", "models", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    {:ok, models} = Settings.list_model_profiles()

    {:ok,
     %{
       message: message(models),
       status: PermissionGate.response_status(permission_decision),
       models: models,
       actions: [
         %{
           name: "list_model_profiles",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{model_count: length(models)}
         }
       ]
     }}
  end

  defp message(models) do
    rendered =
      models
      |> Enum.map(
        &"- #{&1.name}: provider=#{&1.provider}, model=#{&1.model}, credential=#{&1.credential_status}"
      )
      |> Enum.join("\n")

    "Model profiles:\n\n#{rendered}"
  end
end
