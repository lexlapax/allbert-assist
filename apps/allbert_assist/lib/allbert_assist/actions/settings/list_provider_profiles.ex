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
    schema: [render_mode: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    render_mode = render_mode(params, context)
    {:ok, providers} = Settings.list_provider_profiles()

    {:ok,
     %{
       message: message(providers, render_mode),
       status: PermissionGate.response_status(permission_decision),
       providers: providers,
       actions: [
         %{
           name: "list_provider_profiles",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{provider_count: length(providers), render_mode: render_mode}
         }
       ]
     }}
  end

  defp message(providers, :operator_report) do
    rendered =
      providers
      |> Enum.map(
        &"- #{&1.name}: #{&1.type}, endpoint_kind=#{&1.endpoint_kind}, enabled=#{&1.enabled}, credential=#{&1.credential_status}"
      )
      |> Enum.join("\n")

    "Provider profiles:\n\n#{rendered}"
  end

  defp message(providers, :assistant_summary) do
    total = length(providers)
    enabled = Enum.count(providers, & &1.enabled)

    "Provider registry has #{total} profiles loaded (#{enabled} enabled). I can discuss " <>
      "provider setup safely here, but I won't dump the full operator report in chat. " <>
      "Use `mix allbert.settings providers list` for the full operator report."
  end

  defp render_mode(params, context) do
    case field(params, :render_mode) || field(params, :mode) || field(context, :render_mode) do
      value when value in [:operator_report, "operator_report", :raw, "raw"] -> :operator_report
      _other -> :assistant_summary
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
