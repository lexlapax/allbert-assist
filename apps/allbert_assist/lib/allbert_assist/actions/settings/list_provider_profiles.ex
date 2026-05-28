defmodule AllbertAssist.Actions.Settings.ListProviderProfiles do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_provider_profiles",
    description: "List provider profiles with redacted credential status.",
    category: "settings",
    tags: ["settings", "providers", "read_only"],
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
    {:ok, providers} = Settings.list_provider_profiles()

    {:ok,
     %{
       message: message(providers),
       status: PermissionGate.response_status(permission_decision),
       providers: providers,
       actions: [
         %{
           name: "list_provider_profiles",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{provider_count: length(providers)}
         }
       ]
     }}
  end

  defp message(providers) do
    rendered =
      providers
      |> Enum.map(
        &"- #{&1.name}: #{&1.type}, endpoint_kind=#{&1.endpoint_kind}, enabled=#{&1.enabled}, credential=#{&1.credential_status}"
      )
      |> Enum.join("\n")

    "Provider profiles:\n\n#{rendered}"
  end
end
