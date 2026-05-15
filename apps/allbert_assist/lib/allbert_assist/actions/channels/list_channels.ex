defmodule AllbertAssist.Actions.Channels.ListChannels do
  @moduledoc false

  use Jido.Action,
    name: "list_channels",
    description: "List configured Allbert channel adapters.",
    category: "channels",
    tags: ["channels", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Channels
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      channels = Channels.list_channels()

      {:ok,
       %{
         message: message(channels),
         status: :completed,
         channels: channels,
         actions: [action(:completed, permission_decision, %{channel_count: length(channels)})]
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

  defp message([]), do: "No configured channels."

  defp message(channels) do
    channels
    |> Enum.map(fn channel ->
      "- #{channel.channel} provider=#{channel.provider} enabled=#{channel.enabled} identities=#{channel.identity_count}"
    end)
    |> Enum.join("\n")
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
end
