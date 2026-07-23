defmodule AllbertAssist.Channels.Notify do
  @moduledoc """
  ADR 0084 authority boundary for unattended channel notifications.

  Capability declarations do not grant this authority. Every send is checked
  against release availability, per-channel Settings Central consent, level,
  throttle, Security Central policy, and the exact persisted origin identity.
  """

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Channels.Outbound
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security
  alias AllbertAssist.Signals

  @kinds [:status, :completion, :confirmation_request, :consent_offer]

  @doc "Settings Central fragment shared by channel plugins."
  def settings_schema(channel, opts \\ []) when is_binary(channel) do
    levels =
      if Keyword.get(opts, :completion_only, false),
        do: ["completion"],
        else: ["completion", "status_and_completion"]

    [
      %{key: "channels.#{channel}.autonomous_notify.enabled", type: :boolean, default: false},
      %{
        key: "channels.#{channel}.autonomous_notify.level",
        type: :enum,
        default: "completion",
        allowed_values: levels
      },
      %{
        key: "channels.#{channel}.autonomous_notify.min_interval_seconds",
        type: :bounded_integer,
        default: 30,
        min: 5,
        max: 600
      }
    ]
  end

  @doc "Deliver one redacted notification, or persist why it was suppressed."
  def deliver(fanout_or_id, kind, body, opts \\ [])
      when kind in @kinds and is_binary(body) and is_list(opts) do
    with {:ok, fanout} <- fanout(fanout_or_id),
         {:ok, delivery} <- reserve(fanout, kind, opts) do
      authorize_and_send(delivery, fanout, kind, body, opts)
    else
      {:terminal, %NotifyDelivery{} = delivery} -> {:ok, delivery}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reserve the one-time in-band consent offer; true means it should render."
  def prepare_consent_offer(%Objective{} = fanout) do
    if consent_offer_blocked?(fanout) do
      false
    else
      fanout
      |> reserve(:consent_offer,
        delivery_key: "notify_offer_#{fanout.source_channel}_#{fanout.user_id}"
      )
      |> consent_offer_pending?()
    end
  end

  defp consent_offer_blocked?(fanout) do
    local_surface? = fanout.source_channel in ["web", "live_view", "cli", "tui"]

    enabled? =
      case Channels.channel_settings(fanout.source_channel) do
        {:ok, settings} -> get_in(settings, ["autonomous_notify", "enabled"]) == true
        _other -> false
      end

    local_surface? or enabled?
  end

  defp consent_offer_pending?({status, %NotifyDelivery{offer_state: state}})
       when status in [:ok, :terminal],
       do: state not in ["delivered", "accepted"]

  defp consent_offer_pending?(_result), do: false

  def mark_consent_offer_delivered(%{channel: channel, user_id: user_id})
      when is_binary(channel) and is_binary(user_id) do
    from(d in NotifyDelivery,
      where:
        d.channel == ^channel and d.local_user_id == ^user_id and d.kind == "consent_offer" and
          d.offer_state == "pending"
    )
    |> Repo.update_all(
      set: [state: "delivered", offer_state: "delivered", updated_at: DateTime.utc_now()]
    )

    :ok
  end

  def mark_consent_offer_delivered(_response), do: :ok

  def accept_consent(channel, user_id) do
    from(d in NotifyDelivery,
      where: d.channel == ^channel and d.local_user_id == ^user_id and d.kind == "consent_offer"
    )
    |> Repo.update_all(set: [offer_state: "accepted", updated_at: DateTime.utc_now()])

    :ok
  end

  defp authorize_and_send(delivery, fanout, kind, body, opts) do
    channel = fanout.source_channel

    with :ok <- live_use(channel),
         {:ok, settings} <- Channels.channel_settings(channel),
         :ok <- enabled(settings, kind),
         :ok <- level(settings, kind),
         :ok <- throttle(fanout, channel, kind, settings, delivery),
         {:ok, decision} <- security(fanout, channel, kind),
         {:ok, target, thread} <- exact_target(fanout, settings),
         {:ok, sending} <-
           transition(delivery, %{state: "sending", attempt_count: delivery.attempt_count + 1}),
         result <-
           dispatch(opts, sending, fanout, kind, channel, target, Redactor.redact(body), thread) do
      settle_transport(sending, result, decision)
    else
      {:terminal, %NotifyDelivery{} = existing} -> {:ok, existing}
      {:error, reason} -> suppress(delivery, reason)
    end
  end

  defp fanout(%Objective{} = objective), do: {:ok, objective}

  defp fanout(id) when is_binary(id) do
    case Repo.get(Objective, id) do
      %Objective{fanout_role: "parent"} = objective -> {:ok, objective}
      %Objective{} -> {:error, :not_fanout_parent}
      nil -> {:error, :fanout_not_found}
    end
  end

  defp reserve(fanout, kind, opts) do
    delivery_key = Keyword.get(opts, :delivery_key) || delivery_key(fanout.id, kind, opts)

    attrs = %{
      delivery_key: delivery_key,
      fanout_id: fanout.id,
      child_objective_id: Keyword.get(opts, :child_objective_id),
      local_user_id: fanout.user_id,
      channel: fanout.source_channel || "unknown",
      origin_thread_ref_id: fanout.origin_thread_ref_id || "missing",
      origin_thread_ref_digest: fanout.origin_thread_ref_digest || "missing",
      kind: Atom.to_string(kind),
      offer_state: if(kind == :consent_offer, do: "pending", else: "not_applicable")
    }

    case %NotifyDelivery{} |> NotifyDelivery.changeset(attrs) |> Repo.insert() do
      {:ok, delivery} -> {:ok, delivery}
      {:error, changeset} -> existing_delivery(delivery_key, changeset)
    end
  end

  defp existing_delivery(key, changeset) do
    case Repo.get_by(NotifyDelivery, delivery_key: key) do
      %NotifyDelivery{state: state} = delivery when state in ~w[delivered uncertain suppressed] ->
        {:terminal, delivery}

      %NotifyDelivery{state: "failed", attempt_count: attempts} = delivery when attempts < 2 ->
        {:ok, delivery}

      %NotifyDelivery{} = delivery ->
        {:terminal, delivery}

      nil ->
        {:error, changeset}
    end
  end

  defp live_use(channel) do
    if Channels.channel_live_use_allowed?(channel),
      do: :ok,
      else: {:error, Channels.channel_live_use_error(channel)}
  end

  defp enabled(_settings, :consent_offer), do: :ok

  defp enabled(settings, _kind) do
    if get_in(settings, ["autonomous_notify", "enabled"]) == true,
      do: :ok,
      else: {:error, :notify_disabled}
  end

  defp level(_settings, kind) when kind in [:completion, :confirmation_request, :consent_offer],
    do: :ok

  defp level(settings, :status) do
    if get_in(settings, ["autonomous_notify", "level"]) == "status_and_completion",
      do: :ok,
      else: {:error, :status_level_disabled}
  end

  defp throttle(_fanout, _channel, kind, _settings, _delivery) when kind != :status, do: :ok

  defp throttle(fanout, channel, :status, settings, delivery) do
    interval = get_in(settings, ["autonomous_notify", "min_interval_seconds"]) || 30
    cutoff = DateTime.add(DateTime.utc_now(), -interval, :second)

    recent? =
      Repo.exists?(
        from d in NotifyDelivery,
          where:
            d.id != ^delivery.id and d.fanout_id == ^fanout.id and d.channel == ^channel and
              d.kind == "status" and d.state in ["sending", "delivered"] and
              d.throttle_at > ^cutoff
      )

    if recent?, do: {:error, :throttled}, else: :ok
  end

  defp security(fanout, channel, kind) do
    decision =
      Security.authorize(:channel_autonomous_notify, %{
        actor: fanout.user_id,
        operator_id: fanout.user_id,
        channel: channel,
        notification_kind: kind
      })

    if decision.decision == :allowed, do: {:ok, decision}, else: {:error, :security_denied}
  end

  defp exact_target(fanout, settings) do
    with {id, ""} <- Integer.parse(fanout.origin_thread_ref_id || ""),
         %ThreadChannelRef{} = ref <- Repo.get(ThreadChannelRef, id),
         true <- ref.channel == fanout.source_channel,
         true <- ref.receiver_account_ref == fanout.origin_receiver_account_ref,
         true <- digest(ref) == fanout.origin_thread_ref_digest,
         {:ok, external_user_id} <- unique_current_identity(settings, fanout.user_id),
         :ok <- verify_origin_identity(ref.provider_thread_ref, external_user_id),
         {:ok, target} <- transport_target(ref.channel, ref.provider_thread_ref, external_user_id) do
      {:ok, target, ref.provider_thread_ref}
    else
      nil -> {:error, :origin_thread_ref_missing}
      false -> {:error, :origin_thread_ref_mismatch}
      :error -> {:error, :origin_thread_ref_invalid}
      {:error, reason} -> {:error, reason}
      {_id, _rest} -> {:error, :origin_thread_ref_invalid}
    end
  end

  defp unique_current_identity(settings, user_id) do
    matches =
      settings
      |> Map.get("identity_map", [])
      |> Enum.filter(
        &(field(&1, "enabled", true) != false and to_string(field(&1, "user_id")) == user_id)
      )

    case matches do
      [entry] -> {:ok, to_string(field(entry, "external_user_id"))}
      [] -> {:error, :identity_not_mapped}
      _many -> {:error, :identity_conflict}
    end
  end

  defp verify_origin_identity(ref, external_user_id) do
    if field(ref, "origin_identity_digest") == ChannelThread.identity_digest(external_user_id),
      do: :ok,
      else: {:error, :origin_identity_remapped}
  end

  defp transport_target("telegram", ref, _external), do: required_target(ref, ~w[chat_id])
  defp transport_target("email", _ref, external), do: {:ok, external}
  defp transport_target("discord", ref, _external), do: required_target(ref, ~w[channel_id])

  defp transport_target("slack", ref, _external),
    do: required_target(ref, ~w[channel_id conversation_id])

  defp transport_target("matrix", ref, _external), do: required_target(ref, ~w[room_id])
  defp transport_target("whatsapp", _ref, external), do: {:ok, external}
  defp transport_target("signal", _ref, external), do: {:ok, external}
  defp transport_target(_channel, _ref, _external), do: {:error, :unsupported_notify_channel}

  defp required_target(ref, keys) do
    Enum.find_value(keys, fn key ->
      case field(ref, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _other -> nil
      end
    end) || {:error, :origin_target_missing}
  end

  defp outbound(opts, channel, target, body, thread) do
    configured = Application.get_env(:allbert_assist, __MODULE__, [])

    case Keyword.get(opts, :outbound_fun) || Keyword.get(configured, :outbound_fun) do
      fun when is_function(fun, 4) -> fun.(channel, target, body, thread: thread)
      _other -> Outbound.send(channel, target, body, thread: thread)
    end
  end

  defp dispatch(opts, delivery, fanout, :status, channel, target, body, thread) do
    if edit_in_place?(channel) do
      edit_or_append(opts, delivery, fanout, channel, target, body, thread)
    else
      outbound(opts, channel, target, body, thread)
    end
  end

  defp dispatch(opts, _delivery, _fanout, _kind, channel, target, body, thread),
    do: outbound(opts, channel, target, body, thread)

  defp edit_or_append(opts, delivery, fanout, channel, target, body, thread) do
    case latest_status_message(fanout, delivery) do
      nil ->
        outbound(opts, channel, target, body, thread)

      provider_message_id ->
        case edit_outbound(opts, channel, target, provider_message_id, body, thread) do
          {:ok, receipt} ->
            {:ok, Map.put(receipt, :provider_message_id, provider_message_id)}

          {:error, {:uncertain, _reason}} = uncertain ->
            uncertain

          {:error, edit_reason} ->
            append_after_edit_failure(opts, channel, target, body, thread, edit_reason)
        end
    end
  end

  defp append_after_edit_failure(opts, channel, target, body, thread, edit_reason) do
    case outbound(opts, channel, target, body, thread) do
      {:ok, receipt} -> {:ok, receipt, {:edit_fallback, edit_reason}}
      error -> error
    end
  end

  defp edit_outbound(opts, channel, target, provider_message_id, body, thread) do
    configured = Application.get_env(:allbert_assist, __MODULE__, [])

    case Keyword.get(opts, :edit_fun) || Keyword.get(configured, :edit_fun) do
      fun when is_function(fun, 5) ->
        fun.(channel, target, provider_message_id, body, thread: thread)

      _other ->
        Outbound.edit(channel, target, provider_message_id, body, thread: thread)
    end
  end

  defp edit_in_place?(channel) do
    case Channels.channel_descriptor(channel) do
      {:ok, descriptor} ->
        Map.get(descriptor, :status_update_mode, :append_only) == :edit_in_place

      _other ->
        false
    end
  end

  defp latest_status_message(fanout, delivery) do
    from(d in NotifyDelivery,
      where:
        d.id != ^delivery.id and d.fanout_id == ^fanout.id and d.channel == ^fanout.source_channel and
          d.kind == "status" and d.state == "delivered" and
          not is_nil(d.provider_message_id),
      order_by: [desc: d.throttle_at, desc: d.inserted_at],
      limit: 1,
      select: d.provider_message_id
    )
    |> Repo.one()
  end

  defp settle_transport(delivery, {:ok, receipt}, decision) do
    provider_message_id = receipt_id(receipt)

    complete(
      delivery,
      :delivered,
      %{
        state: "delivered",
        provider_message_id: provider_message_id,
        throttle_at: DateTime.utc_now(),
        error_class: nil,
        offer_state:
          if(delivery.kind == "consent_offer", do: "delivered", else: delivery.offer_state)
      },
      decision
    )
  end

  defp settle_transport(delivery, {:ok, receipt, {:edit_fallback, reason}}, decision) do
    provider_message_id = receipt_id(receipt)

    complete(
      delivery,
      :delivered,
      %{
        state: "delivered",
        provider_message_id: provider_message_id,
        throttle_at: DateTime.utc_now(),
        error_class: "edit_fallback:" <> safe_reason(reason)
      },
      decision
    )
  end

  defp settle_transport(delivery, {:error, {:uncertain, reason}}, decision) do
    complete(
      delivery,
      :uncertain,
      %{state: "uncertain", error_class: safe_reason(reason)},
      decision
    )
  end

  defp settle_transport(delivery, {:error, reason}, decision) do
    complete(delivery, :failed, %{state: "failed", error_class: safe_reason(reason)}, decision)
  end

  defp settle_transport(delivery, other, decision),
    do: settle_transport(delivery, {:error, {:invalid_transport_result, other}}, decision)

  defp suppress(delivery, reason) do
    decision = Security.authorize(:channel_autonomous_notify, %{})

    complete(
      delivery,
      :suppressed,
      %{state: "suppressed", error_class: safe_reason(reason)},
      decision
    )
  end

  defp complete(delivery, event, attrs, decision) do
    with {:ok, updated} <- transition(delivery, attrs) do
      metadata = audit_metadata(updated, event)
      audit_result = Audit.append(:channel_notify, event, metadata, decision)
      Signals.emit_channel_notify(event, metadata)

      case audit_result do
        {:ok, _path} -> {:ok, updated}
        {:error, reason} -> {:error, {:audit_failed, reason, updated}}
      end
    end
  end

  defp transition(delivery, attrs),
    do: delivery |> NotifyDelivery.changeset(attrs) |> Repo.update()

  defp audit_metadata(delivery, event) do
    %{
      delivery_key: delivery.delivery_key,
      fanout_id: delivery.fanout_id,
      child_objective_id: delivery.child_objective_id,
      channel: delivery.channel,
      kind: delivery.kind,
      state: delivery.state,
      reason: delivery.error_class,
      attempt_count: delivery.attempt_count,
      event: event
    }
  end

  defp delivery_key(fanout_id, kind, opts) do
    event_key =
      Keyword.get(
        opts,
        :event_key,
        if(kind == :status, do: System.unique_integer([:positive]), else: "terminal")
      )

    digest =
      :crypto.hash(:sha256, "#{fanout_id}:#{kind}:#{event_key}")
      |> Base.url_encode64(padding: false)

    "notify_#{digest}"
  end

  defp digest(ref) do
    %{
      id: to_string(ref.id),
      owner_scope: ref.owner_scope,
      channel: ref.channel,
      receiver_account_ref: ref.receiver_account_ref,
      provider_thread_key: ref.provider_thread_key,
      provider_thread_ref: ref.provider_thread_ref,
      trust_class: ref.trust_class
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp receipt_id(receipt) when is_map(receipt) do
    receipt
    |> then(fn receipt ->
      field(receipt, "provider_message_id") || field(receipt, "message_id") ||
        field(receipt, "event_id") || field(receipt, "ts") || field(receipt, "id") ||
        receipt_id(field(receipt, "result"))
    end)
    |> normalize_receipt_id()
  end

  defp receipt_id(_receipt), do: nil

  defp normalize_receipt_id(value) when is_binary(value), do: value
  defp normalize_receipt_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_receipt_id(_value), do: nil

  defp safe_reason(reason),
    do: reason |> Redactor.redact() |> inspect(limit: 20) |> String.slice(0, 128)

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, String.to_atom(key), default))
end
