defmodule AllbertAssist.Actions.Channels.LinkChannelIdentity do
  @moduledoc """
  v0.62 M8.15 — create an explicit cross-channel identity link on the one action
  spine.

  Config-level identity mapping, so gated by `:settings_write` and audited
  through the Runner; the write itself is delegated to
  `Conversations.ChannelThread.link_identity/1`.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :channel_identity_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "link_channel_identity",
    description: "Create an explicit cross-channel identity link (gated + audited).",
    category: "channels",
    tags: ["channels", "identity", "link"],
    schema: [
      link_id: [type: :string, required: true],
      user_id: [type: :string, required: true],
      channel: [type: :string, required: true],
      receiver_account_ref: [type: :string, required: true],
      external_user_id: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      link: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Security.PermissionGate

  @attr_keys [:link_id, :user_id, :channel, :receiver_account_ref, :external_user_id]

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    attrs = Map.take(params, @attr_keys)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, link} <- ChannelThread.link_identity(attrs) do
      {:ok,
       %{
         message: "Linked #{link.link_id} #{link.channel} identity.",
         status: :completed,
         permission_decision: permission_decision,
         link: link,
         actions: [action(:completed, permission_decision, link_metadata(link))]
       }}
    else
      false -> {:ok, denied(attrs, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(attrs, permission_decision, reason)}
    end
  end

  defp denied(attrs, permission_decision, reason) do
    %{
      message: "I could not link the channel identity: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [
        action(:denied, permission_decision, Map.put(attr_metadata(attrs), :error, reason))
      ]
    }
  end

  defp denied_status(permission_decision, :permission_denied),
    do: PermissionGate.response_status(permission_decision)

  defp denied_status(_permission_decision, _reason), do: :denied

  defp action(status, permission_decision, metadata) do
    %{
      name: "link_channel_identity",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end

  defp link_metadata(link) do
    %{link_id: link.link_id, channel: link.channel, user_id: link.user_id}
  end

  defp attr_metadata(attrs) do
    %{
      link_id: Map.get(attrs, :link_id),
      channel: Map.get(attrs, :channel),
      user_id: Map.get(attrs, :user_id)
    }
  end
end
