defmodule AllbertAssist.Actions.Channels.SendChannelMessage do
  @moduledoc """
  v0.54 M10 (ADR 0063) — operator-initiated outbound channel message.

  Outbound-target gating happens **before** any dispatch (ADR 0016/0056/0059): the
  `target` is resolved against the channel's identity allowlist; an un-allowlisted /
  disabled target is rejected outright (no confirmation, no send). Allowlisted sends
  are `confirmation: :required` via `Actions.Outbound.Gate`; on approval the message
  is dispatched through the single `Channels.Outbound` boundary (never a provider
  client directly). Routing grants no authority.
  """
  use AllbertAssist.Action,
    permission: :channel_message_send,
    exposure: :agent,
    execution_mode: :channel_post,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "send_channel_message",
    description: "Send an outbound message to a channel (gated + confirmation-gated).",
    category: "channels",
    tags: ["channels", "outbound", "send"],
    schema: [
      channel: [type: :string, required: true],
      target: [type: :string, required: true],
      body: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Outbound.Gate
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Outbound
  alias AllbertAssist.Maps

  def intent_descriptors do
    [
      %{
        action_name: "send_channel_message",
        label: "Send an outbound channel message",
        examples: [
          "send a slack message to #eng saying hi",
          "send a discord message to #general with body release is ready",
          "send a telegram message to @alice saying hello",
          "send the exact message hello world to my configured telegram channel"
        ],
        synonyms: ["send channel message", "send slack message", "send discord message"],
        required_slots: [:channel, :target, :body],
        slot_extractors: %{
          channel: :channel_name_phrase,
          target: :channel_target_phrase,
          body: :message_body_phrase
        },
        handoff_required?: true
      }
    ]
  end

  @impl true
  def run(params, context) do
    with {:ok, channel} <- required(params, :channel),
         {:ok, target} <- required(params, :target),
         {:ok, body} <- required(params, :body),
         :ok <- live_channel_available(channel),
         :ok <- gate_target(channel, target) do
      Gate.run(
        %{
          action_name: "send_channel_message",
          permission: :channel_message_send,
          execution_mode: :channel_post,
          summary: %{channel: channel, target: target},
          resume_params: %{channel: channel, target: target, body: body}
        },
        context,
        fn -> Outbound.send(channel, target, body, []) end
      )
    else
      {:error, {:target_rejected, reason}} ->
        {:ok,
         %{
           message:
             "Refusing to send: target #{inspect(reason)} (not allowlisted on this channel).",
           status: :stopped,
           error: {:target_rejected, reason},
           actions: []
         }}

      {:error, {:release_unavailable, status, channel, decision}} ->
        {:ok, unreleased_channel(channel, status, decision)}

      # v1.0.1 M4.3: "my configured <channel> channel" with no single enabled
      # identity-mapped recipient reaches here with an empty target — answer
      # honestly instead of a raw {:missing, :target} inspect dump.
      {:error, {:missing, :target}} ->
        {:ok,
         %{
           message:
             "No message target given and no single enabled identity-mapped recipient " <>
               "is configured for this channel. Try: send a telegram message to @name saying hello",
           status: :stopped,
           error: {:missing, :target},
           actions: []
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "send_channel_message: #{inspect(reason)}",
           status: :failed,
           error: reason,
           actions: []
         }}
    end
  end

  defp live_channel_available(channel) do
    case Channels.channel_live_use_error(channel) do
      {:released, _decision} ->
        :ok

      {status, decision} ->
        {:error, {:release_unavailable, status, channel, decision}}
    end
  end

  defp unreleased_channel(channel, status, decision) do
    %{
      message:
        "Channel #{channel} is implemented but not released for live use: #{decision.decision}",
      status: :stopped,
      error: {status, %{kind: decision.kind, id: decision.id}},
      release_decision: decision,
      actions: [
        %{
          name: "send_channel_message",
          status: :stopped,
          error: {status, %{kind: decision.kind, id: decision.id}},
          release_decision: decision
        }
      ]
    }
  end

  # Resolve the target against the channel identity allowlist before any dispatch.
  defp gate_target(channel, target) do
    identity_map =
      case Channels.channel_settings(channel) do
        {:ok, settings} -> Map.get(settings, "identity_map", [])
        _other -> []
      end

    case Identity.resolve(channel, target, identity_map) do
      {:ok, _user_id} -> :ok
      {:error, reason} -> {:error, {:target_rejected, reason}}
    end
  end

  defp required(params, key) do
    case field(params, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _other -> {:error, {:missing, key}}
    end
  end

  defp field(map, key), do: Maps.field_truthy(map, key)
end
