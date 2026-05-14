defmodule AllbertAssist.Channels do
  @moduledoc """
  Shared substrate for remote/local channel adapters.
  """

  import Ecto.Query

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @known_event_keys [
    :channel,
    :provider,
    :direction,
    :external_event_id,
    :external_user_id,
    :external_chat_id,
    :external_message_id,
    :user_id,
    :session_id,
    :thread_id,
    :input_signal_id,
    :trace_id,
    :status,
    :reason,
    :payload_summary,
    :error
  ]

  @providers %{
    "telegram" => %{
      provider: "telegram_bot_api",
      secret_refs: ["channels.telegram.bot_token_ref"]
    },
    "email" => %{
      provider: "email_imap",
      secret_refs: ["channels.email.imap_password_ref", "channels.email.smtp_password_ref"]
    }
  }

  @spec create_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_event(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known_keys(@known_event_keys)
      |> Map.update(:direction, "inbound", &to_string/1)
      |> Map.update(:status, "received", &to_string/1)
      |> put_outbound_event_id()
      |> bound_summary_fields()

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_event(Event.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def update_event(%Event{} = event, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known_keys(@known_event_keys)
      |> bound_summary_fields()

    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  @spec get_event_by_external_id(String.t(), String.t()) :: Event.t() | nil
  def get_event_by_external_id(channel, external_event_id)
      when is_binary(channel) and is_binary(external_event_id) do
    Repo.one(
      from event in Event,
        where:
          event.channel == ^channel and
            event.external_event_id == ^external_event_id and
            event.direction in ["inbound", "callback"],
        limit: 1
    )
  end

  @spec max_inbound_integer_event_id(String.t()) :: non_neg_integer()
  def max_inbound_integer_event_id(channel) when is_binary(channel) do
    Event
    |> where([event], event.channel == ^channel and event.direction in ["inbound", "callback"])
    |> select([event], event.external_event_id)
    |> Repo.all()
    |> Enum.flat_map(&parse_non_negative_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  @spec derive_session_id(String.t(), String.t(), String.t() | nil) :: String.t()
  def derive_session_id("telegram", external_user_id, external_chat_id) do
    hash_session_id("ch_tg_", ["telegram", external_user_id, external_chat_id])
  end

  def derive_session_id("email", external_user_id, _external_chat_id) do
    hash_session_id("ch_em_", ["email", external_user_id])
  end

  def derive_session_id(channel, external_user_id, external_chat_id) do
    prefix = "ch_" <> String.slice(channel, 0, 2) <> "_"
    hash_session_id(prefix, [channel, external_user_id, external_chat_id])
  end

  @spec list_channels() :: [map()]
  def list_channels do
    Enum.map(["telegram", "email"], &channel_summary/1)
  end

  @spec channel_settings(String.t()) :: {:ok, map()} | {:error, :unknown_channel}
  def channel_settings(channel) when channel in ["telegram", "email"] do
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         channel_settings when is_map(channel_settings) <- get_in(settings, ["channels", channel]) do
      {:ok, channel_settings}
    else
      _other -> {:error, :unknown_channel}
    end
  end

  def channel_settings(_channel), do: {:error, :unknown_channel}

  defp channel_summary(channel) do
    settings =
      case channel_settings(channel) do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    %{
      channel: channel,
      provider: @providers[channel].provider,
      enabled: Map.get(settings, "enabled", false),
      identity_count: settings |> Map.get("identity_map", []) |> length(),
      credential_status: credential_status(channel),
      last_event: last_event_summary(channel)
    }
  end

  defp credential_status(channel) do
    {:ok, channel_settings} = channel_settings(channel)

    @providers
    |> Map.fetch!(channel)
    |> Map.fetch!(:secret_refs)
    |> Enum.map(fn key ->
      ref_key = key |> String.split(".") |> List.last()

      case Map.get(channel_settings, ref_key) do
        ref when is_binary(ref) ->
          {key, Secrets.status(ref)}

        _other ->
          {key, :missing}
      end
    end)
    |> Map.new()
  end

  defp last_event_summary(channel) do
    Event
    |> where([event], event.channel == ^channel)
    |> order_by([event], desc: event.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        nil

      event ->
        %{
          id: event.id,
          direction: event.direction,
          status: event.status,
          external_event_id: event.external_event_id,
          user_id: event.user_id,
          inserted_at: event.inserted_at
        }
    end
  end

  defp put_outbound_event_id(%{direction: "outbound"} = attrs) do
    Map.put_new(attrs, :external_event_id, "out_#{Ecto.UUID.generate()}")
  end

  defp put_outbound_event_id(attrs), do: attrs

  defp bound_summary_fields(attrs) do
    attrs
    |> bound_string(:reason)
    |> bound_string(:payload_summary)
    |> bound_string(:error)
  end

  defp bound_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> Map.put(attrs, key, String.slice(value, 0, 500))
      _value -> attrs
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= 0 -> [integer]
      _other -> []
    end
  end

  defp hash_session_id(prefix, parts) do
    raw =
      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(":", &to_string/1)

    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    prefix <> String.slice(hash, 0, 32)
  end

  defp atomize_known_keys(attrs, known_keys) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      atom_key = known_key(key, known_keys)
      Map.put(acc, atom_key, value)
    end)
  end

  defp known_key(key, _known_keys) when is_atom(key), do: key

  defp known_key(key, known_keys) when is_binary(key) do
    Enum.find(known_keys, key, &(Atom.to_string(&1) == key))
  end
end
