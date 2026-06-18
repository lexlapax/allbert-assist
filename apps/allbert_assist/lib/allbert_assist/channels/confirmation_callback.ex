defmodule AllbertAssist.Channels.ConfirmationCallback do
  @moduledoc """
  Shared guard for remote channel confirmation callbacks.

  Channel adapters must re-resolve the clicker and prove the pending belongs to
  the same local user and origin channel before invoking confirmation actions.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Confirmations

  @typed_command_re ~r/\AALLBERT:(APPROVE|DENY|SHOW):([A-Za-z0-9_-]+)\z/i
  @display_name_prefixed_typed_command_re ~r/\A[^:\r\n]{1,80}:(ALLBERT:(?:APPROVE|DENY|SHOW):[A-Za-z0-9_-]+)\z/i

  @type action :: :approve | :deny | :show | String.t()

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(attrs) when is_map(attrs) do
    with {:ok, action_name} <- action_name(field(attrs, :action)),
         {:ok, confirmation_id} <- required_string(field(attrs, :confirmation_id)),
         {:ok, channel} <- required_string(field(attrs, :channel)),
         {:ok, user_id} <- verify_identity_proof(attrs, channel),
         attrs <- Map.put(attrs, :user_id, user_id),
         {:ok, %{"status" => "pending"} = record} <- read_pending(confirmation_id),
         :ok <- verify_user(record, user_id),
         :ok <- verify_channel(record, channel),
         {:ok, response} <- Runner.run(action_name, %{id: confirmation_id}, context(attrs)) do
      {:ok, response}
    end
  end

  def run(_attrs), do: {:error, :invalid_callback}

  @spec parse_typed_command(String.t(), keyword()) ::
          {:ok, :approve | :deny | :show, String.t()} | :ignore
  def parse_typed_command(text, opts \\ [])

  @spec parse_typed_command(String.t()) ::
          {:ok, :approve | :deny | :show, String.t()} | :ignore
  def parse_typed_command(text, opts) when is_binary(text) and is_list(opts) do
    text
    |> typed_command_candidates(opts)
    |> Enum.find_value(:ignore, &parse_exact_typed_command/1)
  end

  def parse_typed_command(_text, _opts), do: :ignore

  defp parse_exact_typed_command(text) do
    case Regex.run(@typed_command_re, text) do
      [_full, action, confirmation_id] ->
        {:ok, action |> String.downcase() |> String.to_atom(), confirmation_id}

      _match ->
        nil
    end
  end

  defp typed_command_candidates(text, opts) do
    trimmed = String.trim(text)

    line_candidates =
      if Keyword.get(opts, :line_fallback?, false) do
        text
        |> String.split(["\r\n", "\n"], trim: true)
        |> Enum.map(&String.trim/1)
      else
        []
      end

    display_name_candidates =
      if Keyword.get(opts, :display_name_prefix?, false) do
        [trimmed | line_candidates]
        |> Enum.flat_map(&strip_display_name_prefix/1)
      else
        []
      end

    [trimmed | line_candidates ++ display_name_candidates]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp strip_display_name_prefix(text) do
    case Regex.run(@display_name_prefixed_typed_command_re, text) do
      [_full, command] -> [command]
      _match -> []
    end
  end

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

  defp verify_identity_proof(attrs, channel) do
    case field(attrs, :identity_proof) do
      proof when is_map(proof) ->
        verify_identity_proof(attrs, channel, proof)

      _missing ->
        {:error, :missing_identity_proof}
    end
  end

  defp verify_identity_proof(attrs, channel, proof) do
    with {:ok, proof_channel} <- required_string(field(proof, :channel)),
         :ok <- verify_same_channel(channel, proof_channel),
         {:ok, claimed_user_id} <- required_string(field(attrs, :user_id)),
         {:ok, proof_user_id} <- required_string(field(proof, :user_id)),
         :ok <- verify_same_user(claimed_user_id, proof_user_id),
         {:ok, external_user_id} <- required_string(field(proof, :external_user_id)),
         identity_map when is_list(identity_map) <- field(proof, :identity_map),
         {:ok, resolved_user_id} <- Identity.resolve(channel, external_user_id, identity_map),
         :ok <- verify_same_user(claimed_user_id, resolved_user_id) do
      {:ok, resolved_user_id}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_identity_proof}
    end
  end

  defp verify_same_channel(channel, proof_channel) do
    if channel_key(channel) == channel_key(proof_channel) do
      :ok
    else
      {:error, :wrong_channel}
    end
  end

  defp verify_same_user(user_id, proof_user_id) do
    if normalize(user_id) == normalize(proof_user_id) do
      :ok
    else
      {:error, :wrong_user}
    end
  end

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
