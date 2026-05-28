defmodule AllbertAssist.Actions.Settings.DoctorModelProfile do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "doctor_model_profile",
    description: "Check a configured model profile without exposing secrets.",
    category: "settings",
    tags: ["settings", "models", "doctor", "read_only"],
    schema: [
      profile: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    profile = profile(params)

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
           name: "doctor_model_profile",
           status: status,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{
             model_profile: profile,
             milestone: "v0.39 M2",
             implemented?: false
           }
         }
       ]
     }}
  end

  defp profile(params), do: field(params, :profile) || field(params, :model_profile) || "local"

  defp message(:unsupported, profile, _decision) do
    "Model profile doctor for #{profile} is registered; provider probes land in v0.39 M2."
  end

  defp message(:denied, _profile, permission_decision), do: permission_decision.reason

  defp diagnostics(:unsupported),
    do: [%{code: :doctor_not_implemented, message: "Provider probes land in v0.39 M2."}]

  defp diagnostics(:denied), do: []

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
