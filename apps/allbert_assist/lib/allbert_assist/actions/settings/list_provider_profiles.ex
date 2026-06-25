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
    {:ok, providers} = Settings.list_provider_profiles()
    visible_providers = bounded(providers, policy)

    {:ok,
     %{
       message: message(visible_providers, length(providers), policy),
       status: PermissionGate.response_status(permission_decision),
       providers: visible_providers,
       actions: [
         %{
           name: "list_provider_profiles",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{
             provider_count: length(providers),
             rendered_count: length(visible_providers),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           }
         }
       ]
     }}
  end

  defp message(providers, total_count, %{render_mode: :operator_report}) do
    rendered =
      providers
      |> Enum.map(
        &"- #{&1.name}: #{&1.type}, endpoint_kind=#{&1.endpoint_kind}, enabled=#{&1.enabled}, credential=#{&1.credential_status}"
      )
      |> Enum.join("\n")

    suffix =
      if length(providers) < total_count do
        "\n\nShowing #{length(providers)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "Provider profiles:\n\n#{rendered}#{suffix}"
  end

  defp message(providers, total_count, %{render_mode: :assistant_summary}) do
    enabled = Enum.count(providers, & &1.enabled)

    "Provider registry has #{total_count} profiles loaded (#{enabled} enabled). I can discuss " <>
      "provider setup safely here, but I won't dump the full operator report in chat. " <>
      "Use `mix allbert.settings providers list` for the full operator report."
  end

  defp bounded(rows, policy), do: Enum.take(rows, policy.max_rows)
end
