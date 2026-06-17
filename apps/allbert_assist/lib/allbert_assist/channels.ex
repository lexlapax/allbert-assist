defmodule AllbertAssist.Channels do
  @moduledoc """
  Shared substrate for remote/local channel adapters.
  """

  import Ecto.Query

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Signals

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

  @spec create_event(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_event(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known_keys(@known_event_keys)
      |> Map.update(:direction, "inbound", &to_string/1)
      |> Map.update(:status, "received", &to_string/1)
      |> put_outbound_event_id()
      |> redact_event_attrs()
      |> bound_summary_fields()

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> tap_event(&emit_created_signals/1)
  end

  @spec update_event(Event.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def update_event(%Event{} = event, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known_keys(@known_event_keys)
      |> redact_event_attrs()
      |> bound_summary_fields()

    event
    |> Event.changeset(attrs)
    |> Repo.update()
    |> tap_event(&emit_updated_signals/1)
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

  @spec received_event_from_duplicate(Ecto.Changeset.t(), String.t()) :: Event.t() | nil
  def received_event_from_duplicate(%Ecto.Changeset{} = changeset, channel)
      when is_binary(channel) do
    external_event_id = Ecto.Changeset.get_field(changeset, :external_event_id)

    if is_binary(external_event_id) and external_event_id != "" do
      Repo.one(
        from event in Event,
          where:
            event.channel == ^channel and
              event.external_event_id == ^external_event_id and
              event.direction in ["inbound", "callback"] and
              event.status == "received",
          limit: 1
      )
    end
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
  def derive_session_id(channel, external_user_id, external_chat_id) do
    case channel_descriptor(channel) do
      {:ok, %{session_strategy: {:telegram_chat, opts}}} ->
        hash_session_id(Keyword.fetch!(opts, :prefix), [
          channel,
          external_user_id,
          external_chat_id
        ])

      {:ok, %{session_strategy: {:email_sender, opts}}} ->
        hash_session_id(Keyword.fetch!(opts, :prefix), [channel, external_user_id])

      {:ok, %{session_strategy: {strategy, opts}}} ->
        prefix = Keyword.get(opts, :prefix, default_session_prefix(channel))
        hash_session_id(prefix, [channel, strategy, external_user_id, external_chat_id])

      {:error, :unknown_channel} ->
        hash_session_id(default_session_prefix(channel), [
          channel,
          external_user_id,
          external_chat_id
        ])
    end
  end

  @spec list_channels() :: [map()]
  def list_channels do
    PluginRegistry.registered_channels()
    |> Enum.sort_by(&channel_order/1)
    |> Enum.map(&channel_summary/1)
  end

  @spec channel_settings(String.t()) :: {:ok, map()} | {:error, :unknown_channel}
  def channel_settings(channel) when is_binary(channel) do
    with {:ok, descriptor} <- channel_descriptor(channel),
         prefix when is_binary(prefix) <- Map.get(descriptor, :settings_prefix),
         {:ok, settings, _user_settings} <- Store.resolved_settings(),
         channel_settings when is_map(channel_settings) <-
           get_in(settings, String.split(prefix, ".")) do
      {:ok, channel_settings}
    else
      _other -> {:error, :unknown_channel}
    end
  end

  def channel_settings(_channel), do: {:error, :unknown_channel}

  @spec channel_descriptor(String.t()) :: {:ok, map()} | {:error, :unknown_channel}
  def channel_descriptor(channel) when is_binary(channel) do
    PluginRegistry.registered_channels()
    |> Enum.find(&(&1.channel_id == channel))
    |> case do
      nil -> {:error, :unknown_channel}
      descriptor -> {:ok, descriptor}
    end
  end

  def channel_descriptor(_channel), do: {:error, :unknown_channel}

  @spec channel_provider(String.t()) :: String.t() | nil
  def channel_provider(channel) do
    case channel_descriptor(channel) do
      {:ok, descriptor} -> descriptor.provider
      {:error, :unknown_channel} -> nil
    end
  end

  @spec channel_child_specs(keyword()) :: [Supervisor.child_spec()]
  def channel_child_specs(opts \\ []) do
    PluginRegistry.registered_channels()
    |> Enum.filter(&(&1.status == :enabled))
    |> Enum.map(&descriptor_child_spec(&1, opts))
  end

  defp descriptor_child_spec(%{child_spec: {module, descriptor_opts}} = descriptor, opts) do
    Supervisor.child_spec({module, Keyword.merge(descriptor_opts, opts)},
      id: descriptor.channel_id
    )
  end

  defp descriptor_child_spec(%{child_spec: module} = descriptor, opts) when is_atom(module) do
    Supervisor.child_spec({module, opts}, id: descriptor.channel_id)
  end

  defp descriptor_child_spec(%{child_spec: child_spec}, _opts),
    do: Supervisor.child_spec(child_spec, [])

  defp legacy_channel_settings(channel) when channel in ["telegram", "email"] do
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         channel_settings when is_map(channel_settings) <- get_in(settings, ["channels", channel]) do
      {:ok, channel_settings}
    else
      _other -> {:error, :unknown_channel}
    end
  end

  defp legacy_channel_settings(_channel), do: {:error, :unknown_channel}

  defp channel_summary(descriptor) do
    channel = descriptor.channel_id

    settings =
      case channel_settings(channel) do
        {:ok, settings} ->
          settings

        {:error, _reason} ->
          case legacy_channel_settings(channel) do
            {:ok, settings} -> settings
            {:error, _reason} -> %{}
          end
      end

    %{
      channel: channel,
      provider: descriptor.provider,
      plugin_id: descriptor.plugin_id,
      source: descriptor.source,
      enabled: Map.get(settings, "enabled", false),
      identity_count: settings |> Map.get("identity_map", []) |> length(),
      credential_status: credential_status(descriptor),
      last_event: last_event_summary(channel)
    }
  end

  defp credential_status(%{channel_id: channel} = descriptor) do
    channel_settings =
      case channel_settings(channel) do
        {:ok, settings} ->
          settings

        {:error, _reason} ->
          case legacy_channel_settings(channel) do
            {:ok, settings} -> settings
            {:error, _reason} -> %{}
          end
      end

    descriptor
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

  defp default_session_prefix(channel), do: "ch_" <> String.slice(to_string(channel), 0, 2) <> "_"

  defp channel_order(%{channel_id: "telegram"}), do: {0, "telegram"}
  defp channel_order(%{channel_id: "email"}), do: {1, "email"}
  defp channel_order(%{channel_id: channel_id}), do: {10, channel_id}

  defp tap_event({:ok, %Event{} = event} = result, fun) when is_function(fun, 1) do
    fun.(event)
    result
  end

  defp tap_event(result, _fun), do: result

  defp emit_created_signals(%Event{} = event) do
    case event.direction do
      "callback" ->
        emit_channel_signal(:update_received, event)
        emit_channel_signal(:callback_received, event)

      "inbound" ->
        emit_channel_signal(:update_received, event)

      _other ->
        :ok
    end

    emit_status_signal(event)
  end

  defp emit_updated_signals(%Event{} = event), do: emit_status_signal(event)

  defp emit_status_signal(%Event{status: "processed", direction: "inbound"} = event) do
    emit_channel_signal(:runtime_submitted, event)
    emit_channel_signal(:response_sent, event)
  end

  defp emit_status_signal(%Event{status: "processed", direction: "callback"} = event) do
    emit_channel_signal(:response_sent, event)
  end

  defp emit_status_signal(%Event{status: "rejected"} = event) do
    emit_channel_signal(:message_rejected, event)
  end

  defp emit_status_signal(%Event{status: "failed"} = event) do
    emit_channel_signal(:delivery_failed, event)
  end

  defp emit_status_signal(_event), do: :ok

  defp emit_channel_signal(kind, %Event{} = event) do
    metadata = %{
      channel: event.channel,
      provider: event.provider,
      external_event_id: event.external_event_id,
      external_user_id: event.external_user_id,
      external_chat_id: event.external_chat_id,
      external_message_id: event.external_message_id,
      user_id: event.user_id,
      session_id: event.session_id,
      thread_id: event.thread_id,
      trace_id: event.trace_id,
      input_signal_id: event.input_signal_id,
      direction: event.direction,
      status: event.status,
      reason: event.reason,
      error: event.error
    }

    case Signals.channel_lifecycle(kind, metadata) do
      {:ok, signal} -> Signals.log(signal)
      {:error, _reason} -> :ok
    end
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

  defp redact_event_attrs(attrs), do: Redactor.redact(attrs, :audits)

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
