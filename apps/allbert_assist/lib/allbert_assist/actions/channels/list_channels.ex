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
    schema: [render_mode: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Channels
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    render_mode = render_mode(params, context)

    if PermissionGate.allowed?(permission_decision) do
      channels = Channels.list_channels()

      {:ok,
       %{
         message: message(channels, render_mode),
         status: :completed,
         channels: channels,
         actions: [
           action(:completed, permission_decision, %{
             channel_count: length(channels),
             render_mode: render_mode
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

  defp message([], :operator_report), do: "No configured channels."

  defp message(channels, :operator_report) do
    channels
    |> Enum.map(fn channel ->
      "- #{channel.channel} provider=#{channel.provider} enabled=#{channel.enabled} identities=#{channel.identity_count}"
    end)
    |> Enum.join("\n")
  end

  defp message(channels, :assistant_summary) do
    total = length(channels)
    enabled = Enum.count(channels, & &1.enabled)
    disabled = total - enabled

    "Channel registry has #{total} adapters (#{enabled} enabled, #{disabled} disabled). " <>
      "I can discuss channel setup safely here, but I won't dump the operator inventory " <>
      "in chat. Use `/channels` for the TUI operator report."
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_channels",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
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
