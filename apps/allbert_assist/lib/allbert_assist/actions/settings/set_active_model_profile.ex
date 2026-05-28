defmodule AllbertAssist.Actions.Settings.SetActiveModelProfile do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :agent,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "set_active_model_profile",
    description: "Set the active model profile through Settings Central.",
    category: "settings",
    tags: ["settings", "models", "write"],
    schema: [
      profile: [type: :string, required: true],
      enable_assist: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    profile = field(params, :profile) || field(params, :model_profile) || "local"

    status =
      if PermissionGate.allowed?(permission_decision), do: :unsupported, else: :denied

    {:ok,
     %{
       message: message(status, profile, permission_decision),
       status: status,
       permission_decision: permission_decision,
       diagnostics: diagnostics(status),
       actions: [
         %{
           name: "set_active_model_profile",
           status: status,
           permission: :settings_write,
           permission_decision: permission_decision,
           settings_metadata: %{
             model_profile: profile,
             enable_assist: field(params, :enable_assist),
             milestone: "v0.39 M2",
             implemented?: false
           }
         }
       ]
     }}
  end

  defp message(:unsupported, profile, _decision) do
    "Model profile selection for #{profile} is registered; Settings writes land in v0.39 M2."
  end

  defp message(:denied, _profile, permission_decision), do: permission_decision.reason

  defp diagnostics(:unsupported),
    do: [
      %{code: :model_profile_write_not_implemented, message: "Settings writes land in v0.39 M2."}
    ]

  defp diagnostics(:denied), do: []

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
