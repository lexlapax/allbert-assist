defmodule AllbertAssist.Channels.ConfirmationCallback do
  @moduledoc """
  Shared guard for remote channel confirmation callbacks.

  Channel adapters must re-resolve the clicker and prove the pending belongs to
  the same local user and origin channel before invoking confirmation actions.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations

  @typed_command_re ~r/\AALLBERT:(APPROVE|DENY|SHOW):([A-Za-z0-9_-]+)\z/i

  @type action :: :approve | :deny | :show | String.t()

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(attrs) when is_map(attrs) do
    with {:ok, action_name} <- action_name(field(attrs, :action)),
         {:ok, confirmation_id} <- required_string(field(attrs, :confirmation_id)),
         {:ok, user_id} <- required_string(field(attrs, :user_id)),
         {:ok, channel} <- required_string(field(attrs, :channel)),
         {:ok, %{"status" => "pending"} = record} <- read_pending(confirmation_id),
         :ok <- verify_user(record, user_id),
         :ok <- verify_channel(record, channel),
         {:ok, response} <- Runner.run(action_name, %{id: confirmation_id}, context(attrs)) do
      {:ok, response}
    end
  end

  def run(_attrs), do: {:error, :invalid_callback}

  @spec parse_typed_command(String.t()) ::
          {:ok, :approve | :deny | :show, String.t()} | :ignore
  def parse_typed_command(text) when is_binary(text) do
    case Regex.run(@typed_command_re, String.trim(text)) do
      [_full, action, confirmation_id] ->
        {:ok, action |> String.downcase() |> String.to_atom(), confirmation_id}

      _match ->
        :ignore
    end
  end

  def parse_typed_command(_text), do: :ignore

  @spec reply_text(map()) :: String.t()
  def reply_text(%{message: message}) when is_binary(message), do: message
  def reply_text(%{"message" => message}) when is_binary(message), do: message

  def reply_text(%{confirmation: %{"id" => id, "status" => status}}) do
    "Confirmation #{id}: #{status}."
  end

  def reply_text(%{"confirmation" => %{"id" => id, "status" => status}}) do
    "Confirmation #{id}: #{status}."
  end

  def reply_text(response), do: inspect(response, pretty: true)

  defp action_name(action) when action in [:approve, "approve"], do: {:ok, "approve_confirmation"}
  defp action_name(action) when action in [:deny, "deny"], do: {:ok, "deny_confirmation"}
  defp action_name(action) when action in [:show, "show"], do: {:ok, "show_confirmation"}
  defp action_name(_action), do: {:error, :unsupported_callback_action}

  defp read_pending(confirmation_id) do
    case Confirmations.read(confirmation_id) do
      {:ok, %{"status" => "pending"} = record} -> {:ok, record}
      {:ok, %{"status" => status}} -> {:error, {:confirmation_not_pending, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_user(%{"origin" => %{} = origin}, user_id) do
    if normalize(Map.get(origin, "actor")) == normalize(user_id) do
      :ok
    else
      {:error, :wrong_user}
    end
  end

  defp verify_user(_record, _user_id), do: {:error, :wrong_user}

  defp verify_channel(%{"origin" => %{} = origin}, channel) do
    if channel_key(Map.get(origin, "channel")) == channel_key(channel) do
      :ok
    else
      {:error, :wrong_channel}
    end
  end

  defp verify_channel(_record, _channel), do: {:error, :wrong_channel}

  defp context(attrs) do
    user_id = field(attrs, :user_id)
    channel = field(attrs, :channel)
    session_id = field(attrs, :session_id)

    %{
      actor: user_id,
      channel: channel,
      surface: field(attrs, :surface) || "#{channel}_callback",
      session_id: session_id,
      request: %{
        user_id: user_id,
        operator_id: user_id,
        channel: channel,
        session_id: session_id
      },
      resolver_metadata: field(attrs, :resolver_metadata) || %{}
    }
  end

  defp required_string(value) do
    value = normalize(value)
    if value == "", do: {:error, :missing_required_string}, else: {:ok, value}
  end

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim()

  defp channel_key(:liveview), do: "live_view"
  defp channel_key("liveview"), do: "live_view"
  defp channel_key(value), do: normalize(value)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
