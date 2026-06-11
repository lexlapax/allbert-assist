defmodule AllbertAssist.Channels.InboundTrust do
  @moduledoc false

  alias AllbertAssist.Security.Policy

  @spec authorize(map()) :: {:ok, map()} | {:error, :channel_message_inbound_denied}
  def authorize(context) when is_map(context) do
    policy = Policy.resolve(:channel_message_inbound, policy_context(context))

    case policy.effective do
      :denied ->
        {:error, :channel_message_inbound_denied}

      decision ->
        {:ok,
         %{
           permission: :channel_message_inbound,
           decision: decision,
           configured_decision: policy.configured_decision,
           safety_floor: policy.safety_floor,
           reason: policy.reason
         }}
    end
  end

  def authorize(_context), do: {:error, :channel_message_inbound_denied}

  defp policy_context(context) do
    %{
      actor: Map.get(context, :user_id),
      channel: Map.get(context, :channel),
      surface: Map.get(context, :surface),
      external_user_id: Map.get(context, :external_user_id),
      external_chat_id: Map.get(context, :external_chat_id),
      receiver_account_ref: Map.get(context, :receiver_account_ref),
      provider: Map.get(context, :provider)
    }
  end
end
