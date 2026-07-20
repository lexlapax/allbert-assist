defmodule AllbertAssist.Actions.Channels.ListChannels do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_channels",
    description: "List configured Allbert channel adapters.",
    category: "channels",
    tags: ["channels", "read_only"],
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

  alias AllbertAssist.Channels
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    policy = SurfacePolicy.report_policy(name(), params, context)

    if PermissionGate.allowed?(permission_decision) do
      # v1.0.3 M3 (ADR 0086 monolith-class corollary / ADR 0082): honor the
      # internal registry context riding the action context map under
      # `:registry` (the M1 ListApps/ShowApp pattern). Production call sites
      # pass nothing and read the global default. SurfacePolicy above stays a
      # Settings read — it is not a registry seam.
      plugin_opts = context |> registry_opts() |> RegistryContext.plugin_opts()
      channels = Channels.list_channels(plugin_opts)
      visible_channels = bounded(channels, policy)

      {:ok,
       %{
         message: message(visible_channels, length(channels), policy),
         status: :completed,
         channels: visible_channels,
         actions: [
           action(:completed, permission_decision, %{
             channel_count: length(channels),
             rendered_count: length(visible_channels),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           })
         ]
       }}
    else
      {:ok,
       %{
         message: "Channel registry is not available to this request.",
         status: :denied,
         error: :permission_denied,
         actions: [action(:denied, permission_decision, %{error: :permission_denied})]
       }}
    end
  end

  defp message([], _total_count, %{render_mode: :operator_report}), do: "No configured channels."

  defp message(channels, total_count, %{render_mode: :operator_report}) do
    rendered =
      channels
      |> Enum.map(fn channel ->
        "- #{channel.channel} provider=#{channel.provider} enabled=#{channel.enabled} identities=#{channel.identity_count}"
      end)
      |> Enum.join("\n")

    suffix =
      if length(channels) < total_count do
        "\n\nShowing #{length(channels)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "#{rendered}#{suffix}"
  end

  defp message(channels, total, %{render_mode: :assistant_summary}) do
    enabled = Enum.count(channels, & &1.enabled)
    disabled = total - enabled

    "Channel registry has #{total} adapters (#{enabled} enabled, #{disabled} disabled). " <>
      "I can discuss channel setup safely here, but I won't dump the operator inventory " <>
      "in chat. Use `/channels` for the TUI operator report."
  end

  defp registry_opts(%{registry: registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(_context), do: []

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_channels",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end

  defp bounded(rows, policy), do: Enum.take(rows, policy.max_rows)
end
