defmodule AllbertAssist.Channels.Notify do
  @moduledoc """
  ADR 0084 authority boundary for unattended channel notifications.

  Capability declarations do not grant this authority. Every send is checked
  against release availability, per-channel Settings Central consent, level,
  throttle, Security Central policy, and the exact persisted origin identity.
  """

  import Ecto.Query

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Channels.Outbound
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security
  alias AllbertAssist.Signals

  @kinds [:status, :completion, :confirmation_request, :consent_offer]
  @live_attached_channels ~w[tui live_view]
  @non_autonomous_channels ~w[tui web live_view cli acp_stdio openai_api job]
  @completion_event_key "joined"
  @default_completion_work_limit 100
  @completion_scan_batch_size 100

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
    with {:ok, fanout} <- fanout(fanout_or_id) do
      deliver_preflight(fanout, kind, body, opts, delivery_preflight(fanout, kind, opts))
    end
  end

  defp deliver_preflight(_fanout, _kind, _body, _opts, :attached_surface),
    do: {:ok, :attached_surface}

  defp deliver_preflight(fanout, kind, _body, opts, {:suppress, reason, preflight_opts}) do
    reserve_then(fanout, kind, preflight_opts, &suppress(&1, reason, opts))
  end

  defp deliver_preflight(fanout, kind, body, opts, :send) do
    reserve_then(
      fanout,
      kind,
      opts,
      &authorize_and_send(&1, fanout, kind, body, opts)
    )
  end

  defp reserve_then(fanout, kind, opts, continuation) do
    case reserve(fanout, kind, opts) do
      {:ok, delivery} -> continuation.(delivery)
      {:terminal, %NotifyDelivery{} = delivery} -> {:ok, delivery}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Recover one durable pending completion outbox without duplicate transport."
  @spec recover_completion(Objective.t() | String.t(), keyword()) ::
          {:ok, NotifyDelivery.t() | :attached_surface | :not_joined | :not_pending}
          | {:error, term()}
  def recover_completion(fanout_or_id, opts \\ []) when is_list(opts) do
    with {:ok, fanout} <- fanout(fanout_or_id) do
      projection = Fanout.parent_projection(fanout)

      cond do
        fanout.report_delivery_state != "pending" ->
          {:ok, :not_pending}

        projection.phase != :joined or not projection.authoritatively_joined? ->
          {:ok, :not_joined}

        autonomous_delivery_suppressed?(fanout) ->
          {:ok, :attached_surface}

        true ->
          recover_completion_delivery(fanout, opts)
      end
    end
  end

  @doc "List durable completion outboxes that can make progress after restart."
  @spec pending_completion_work(pos_integer()) :: [Objective.t()]
  def pending_completion_work(limit \\ @default_completion_work_limit)
      when is_integer(limit) and limit > 0 do
    scan_pending_completion_work(nil, limit, [])
  end

  defp scan_pending_completion_work(cursor, remaining, accepted) do
    parents = pending_completion_batch(cursor)

    {remaining, accepted, skipped_ids} =
      Enum.reduce_while(parents, {remaining, accepted, []}, &scan_pending_completion_parent/2)

    log_skipped_completion_integrity_failures(skipped_ids)

    cond do
      remaining == 0 ->
        Enum.reverse(accepted)

      length(parents) < @completion_scan_batch_size ->
        Enum.reverse(accepted)

      true ->
        last = List.last(parents)
        scan_pending_completion_work({last.completed_at, last.id}, remaining, accepted)
    end
  end

  defp scan_pending_completion_parent(parent, {remaining, accepted, skipped}) do
    projection = Fanout.parent_projection(parent)

    if projection.phase == :joined and projection.authoritatively_joined? do
      next = {remaining - 1, [parent | accepted], skipped}
      if remaining == 1, do: {:halt, next}, else: {:cont, next}
    else
      {:cont, {remaining, accepted, [parent.id | skipped]}}
    end
  end

  defp pending_completion_batch(cursor) do
    Objective
    |> join(:left, [objective], delivery in NotifyDelivery,
      on: delivery.fanout_id == objective.id and delivery.kind == "completion"
    )
    |> where(
      [objective, delivery],
      objective.fanout_role == "parent" and objective.report_delivery_state == "pending" and
        objective.report_composition_state in ["ready", "fallback"] and
        objective.source_channel not in ^@non_autonomous_channels and
        (is_nil(delivery.id) or delivery.state in ["reserved", "sending", "delivered"] or
           (delivery.state == "failed" and delivery.attempt_count < 2))
    )
    |> after_completion_cursor(cursor)
    |> order_by([objective], asc: objective.completed_at, asc: objective.id)
    |> limit(@completion_scan_batch_size)
    |> Repo.all()
  end

  defp after_completion_cursor(query, nil), do: query

  defp after_completion_cursor(query, {nil, id}) do
    where(
      query,
      [objective, _delivery],
      (is_nil(objective.completed_at) and objective.id > ^id) or
        not is_nil(objective.completed_at)
    )
  end

  defp after_completion_cursor(query, {completed_at, id}) do
    where(
      query,
      [objective, _delivery],
      objective.completed_at > ^completed_at or
        (objective.completed_at == ^completed_at and objective.id > ^id)
    )
  end

  defp log_skipped_completion_integrity_failures([]), do: :ok

  defp log_skipped_completion_integrity_failures(ids) do
    ordered_ids = Enum.reverse(ids)

    Logger.error(
      "notification completion scan skipped report integrity failures " <>
        "count=#{length(ordered_ids)} first_parent_id=#{List.first(ordered_ids)} " <>
        "last_parent_id=#{List.last(ordered_ids)}"
    )
  end

  @doc "Reserve the one-time in-band consent offer; true means it should render."
  def prepare_consent_offer(%Objective{} = fanout, effect_context) do
    if consent_offer_blocked?(fanout) do
      false
    else
      fanout
      |> reserve(:consent_offer,
        delivery_key: "notify_offer_#{fanout.source_channel}_#{fanout.user_id}",
        allbert_pack_epoch: Map.get(effect_context, :allbert_pack_epoch)
      )
      |> consent_offer_pending?()
    end
  end

  def prepare_consent_offer(%Objective{} = _fanout), do: false

  defp consent_offer_blocked?(fanout) do
    autonomous_delivery_suppressed?(fanout) or autonomous_enabled?(fanout)
  end

  defp consent_offer_pending?({status, %NotifyDelivery{offer_state: state}})
       when status in [:ok, :terminal],
       do: state not in ["delivered", "accepted"]

  defp consent_offer_pending?(_result), do: false

  def mark_consent_offer_delivered(%{channel: channel, user_id: user_id}, effect_context)
      when is_binary(channel) and is_binary(user_id) do
    with :ok <- validate_effect_context(effect_context) do
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
  end

  def mark_consent_offer_delivered(_response, _effect_context), do: :ok

  def accept_consent(channel, user_id, effect_context) do
    with :ok <- validate_effect_context(effect_context) do
      from(d in NotifyDelivery,
        where: d.channel == ^channel and d.local_user_id == ^user_id and d.kind == "consent_offer"
      )
      |> Repo.update_all(set: [offer_state: "accepted", updated_at: DateTime.utc_now()])

      :ok
    end
  end

  defp validate_effect_context(%{allbert_pack_epoch: epoch}), do: EffectGuard.validate(epoch)
  defp validate_effect_context(_context), do: {:error, :product_not_ready}

  defp authorize_and_send(delivery, fanout, kind, body, opts) do
    channel = fanout.source_channel

    with :ok <- live_use(channel),
         {:ok, settings} <- Channels.channel_settings(channel),
         :ok <- enabled(settings, kind),
         :ok <- level(settings, kind),
         :ok <- throttle(fanout, channel, kind, settings, delivery),
         {:ok, decision} <- security(fanout, channel, kind),
         {:ok, target, thread} <- exact_target(fanout, settings),
         {:ok, sending} <- claim_delivery(delivery, opts),
         result <-
           safe_dispatch(
             opts,
             sending,
             fanout,
             kind,
             channel,
             target,
             Redactor.redact(body),
             thread
           ) do
      settle_transport(sending, result, decision, opts)
    else
      {:terminal, %NotifyDelivery{} = existing} -> {:ok, existing}
      {:error, reason} -> suppress(delivery, reason, opts)
    end
  end

  defp fanout(%Objective{id: id}), do: fanout(id)

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

    with :ok <- validate_effect_opts(opts) do
      case %NotifyDelivery{} |> NotifyDelivery.changeset(attrs) |> Repo.insert() do
        {:ok, delivery} -> {:ok, delivery}
        {:error, changeset} -> existing_delivery(delivery_key, changeset)
      end
    end
  end

  defp existing_delivery(key, changeset) do
    case Repo.get_by(NotifyDelivery, delivery_key: key) do
      %NotifyDelivery{state: state} = delivery when state in ~w[delivered uncertain suppressed] ->
        {:terminal, delivery}

      %NotifyDelivery{state: "failed", attempt_count: attempts} = delivery when attempts < 2 ->
        {:ok, delivery}

      %NotifyDelivery{state: "reserved"} = delivery ->
        {:ok, delivery}

      %NotifyDelivery{} = delivery ->
        {:terminal, delivery}

      nil ->
        {:error, changeset}
    end
  end

  defp delivery_preflight(fanout, _kind, _opts)
       when fanout.source_channel in @non_autonomous_channels,
       do: :attached_surface

  defp delivery_preflight(fanout, :status, opts) do
    case Channels.channel_settings(fanout.source_channel) do
      {:ok, settings} ->
        cond do
          get_in(settings, ["autonomous_notify", "enabled"]) != true ->
            {:suppress, :notify_disabled,
             stable_status_suppression_opts(opts, fanout, :notify_disabled)}

          get_in(settings, ["autonomous_notify", "level"]) != "status_and_completion" ->
            {:suppress, :status_level_disabled,
             stable_status_suppression_opts(opts, fanout, :status_level_disabled)}

          true ->
            :send
        end

      {:error, reason} ->
        {:suppress, reason, stable_status_suppression_opts(opts, fanout, reason)}
    end
  end

  defp delivery_preflight(_fanout, _kind, _opts), do: :send

  defp stable_status_suppression_opts(opts, fanout, reason) do
    Keyword.put(
      opts,
      :delivery_key,
      delivery_key(fanout.id, :status, event_key: "suppressed:#{safe_reason(reason)}")
    )
  end

  @doc false
  @spec live_attached_surface?(Objective.t()) :: boolean()
  def live_attached_surface?(%Objective{source_channel: channel}),
    do: channel in @live_attached_channels

  @doc false
  @spec autonomous_delivery_suppressed?(Objective.t()) :: boolean()
  def autonomous_delivery_suppressed?(%Objective{source_channel: channel}),
    do: channel in @non_autonomous_channels

  @doc false
  @spec autonomous_enabled?(Objective.t()) :: boolean()
  def autonomous_enabled?(%Objective{source_channel: channel}) do
    case Channels.channel_settings(channel) do
      {:ok, settings} -> get_in(settings, ["autonomous_notify", "enabled"]) == true
      _other -> false
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
         true <- ChannelThread.canonical_ref_digest(ref) == fanout.origin_thread_ref_digest,
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

    with :ok <- validate_effect_opts(opts) do
      transport_opts = transport_opts(opts, thread)

      case Keyword.get(opts, :outbound_fun) || Keyword.get(configured, :outbound_fun) do
        fun when is_function(fun, 4) -> fun.(channel, target, body, transport_opts)
        _other -> Outbound.send(channel, target, body, transport_opts)
      end
    end
  end

  defp safe_dispatch(opts, delivery, fanout, kind, channel, target, body, thread) do
    try do
      dispatch(opts, delivery, fanout, kind, channel, target, body, thread)
    rescue
      exception -> {:error, {:uncertain, {exception.__struct__, Exception.message(exception)}}}
    catch
      caught_kind, reason -> {:error, {:uncertain, {caught_kind, reason}}}
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

    with :ok <- validate_effect_opts(opts) do
      transport_opts = transport_opts(opts, thread)

      case Keyword.get(opts, :edit_fun) || Keyword.get(configured, :edit_fun) do
        fun when is_function(fun, 5) ->
          fun.(channel, target, provider_message_id, body, transport_opts)

        _other ->
          Outbound.edit(channel, target, provider_message_id, body, transport_opts)
      end
    end
  end

  defp transport_opts(opts, thread) do
    opts
    |> Keyword.take([:req_options, :receive_timeout])
    |> Keyword.put(:thread, thread)
    |> Keyword.put(:allbert_pack_epoch, Keyword.fetch!(opts, :allbert_pack_epoch))
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

  defp settle_transport(delivery, {:ok, receipt}, decision, opts) do
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
      decision,
      opts
    )
  end

  defp settle_transport(delivery, {:ok, receipt, {:edit_fallback, reason}}, decision, opts) do
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
      decision,
      opts
    )
  end

  defp settle_transport(delivery, {:error, {:uncertain, reason}}, decision, opts) do
    complete(
      delivery,
      :uncertain,
      %{state: "uncertain", error_class: safe_reason(reason)},
      decision,
      opts
    )
  end

  defp settle_transport(delivery, {:error, reason}, decision, opts) do
    complete(
      delivery,
      :failed,
      %{state: "failed", error_class: safe_reason(reason)},
      decision,
      opts
    )
  end

  defp settle_transport(delivery, other, decision, opts),
    do: settle_transport(delivery, {:error, {:invalid_transport_result, other}}, decision, opts)

  defp suppress(delivery, reason, opts) do
    decision = Security.authorize(:channel_autonomous_notify, %{})

    complete(
      delivery,
      :suppressed,
      %{state: "suppressed", error_class: safe_reason(reason)},
      decision,
      opts
    )
  end

  defp complete(delivery, event, attrs, decision, opts) do
    case transition(delivery, attrs, opts) do
      {:ok, updated} ->
        metadata = audit_metadata(updated, event)

        with :ok <- validate_effect_opts(opts),
             {:ok, _path} <- append_audit(opts, event, metadata, decision),
             :ok <- validate_effect_opts(opts),
             :ok <- Signals.emit_channel_notify(event, metadata) do
          {:ok, updated}
        else
          {:error, reason} -> {:error, {:audit_failed, reason, updated}}
        end

      {:terminal, current} ->
        {:ok, current}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_audit(opts, event, metadata, decision) do
    case Keyword.get(opts, :audit_fun) do
      fun when is_function(fun, 4) -> fun.(:channel_notify, event, metadata, decision)
      _other -> Audit.append(:channel_notify, event, metadata, decision)
    end
  end

  defp claim_delivery(%NotifyDelivery{state: state, attempt_count: attempts} = delivery, opts)
       when state == "reserved" or (state == "failed" and attempts < 2) do
    now = DateTime.utc_now()

    attrs = %{
      state: "sending",
      attempt_count: attempts + 1,
      throttle_at: now,
      error_class: nil,
      updated_at: now
    }

    case compare_and_set(delivery, attrs, opts) do
      {:ok, claimed} -> {:ok, claimed}
      {:terminal, current} -> {:terminal, current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_delivery(%NotifyDelivery{} = delivery, _opts), do: {:terminal, delivery}

  defp transition(%NotifyDelivery{} = delivery, attrs, opts) when is_map(attrs) do
    changeset = NotifyDelivery.changeset(delivery, attrs)

    if changeset.valid? do
      changes = Map.put(changeset.changes, :updated_at, DateTime.utc_now())
      compare_and_set(delivery, changes, opts)
    else
      {:error, changeset}
    end
  end

  defp compare_and_set(delivery, changes, opts) do
    query =
      from current in NotifyDelivery,
        where:
          current.id == ^delivery.id and current.state == ^delivery.state and
            current.attempt_count == ^delivery.attempt_count

    with :ok <- validate_effect_opts(opts) do
      case Repo.update_all(query, set: Map.to_list(changes)) do
        {1, _rows} -> {:ok, Repo.get!(NotifyDelivery, delivery.id)}
        {0, _rows} -> {:terminal, Repo.get!(NotifyDelivery, delivery.id)}
      end
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp validate_effect_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:allbert_pack_epoch)
    |> EffectGuard.validate()
  end

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
        if(kind == :status, do: "status", else: "terminal")
      )

    digest =
      :crypto.hash(:sha256, "#{fanout_id}:#{kind}:#{event_key}")
      |> Base.url_encode64(padding: false)

    "notify_#{digest}"
  end

  defp recover_completion_delivery(fanout, opts) do
    key = completion_delivery_key(fanout)

    case Repo.get_by(NotifyDelivery, delivery_key: key) do
      nil ->
        deliver(
          fanout,
          :completion,
          completion_body(fanout),
          Keyword.put(opts, :delivery_key, key)
        )

      %NotifyDelivery{state: "reserved"} ->
        deliver(
          fanout,
          :completion,
          completion_body(fanout),
          Keyword.put(opts, :delivery_key, key)
        )

      %NotifyDelivery{state: "failed", attempt_count: attempts} when attempts < 2 ->
        deliver(
          fanout,
          :completion,
          completion_body(fanout),
          Keyword.put(opts, :delivery_key, key)
        )

      %NotifyDelivery{state: "sending"} = delivery ->
        decision = Security.authorize(:channel_autonomous_notify, %{})

        complete(
          delivery,
          :uncertain,
          %{state: "uncertain", error_class: "interrupted_while_sending"},
          decision,
          opts
        )

      %NotifyDelivery{} = delivery ->
        {:ok, delivery}
    end
  end

  @doc false
  @spec completion_delivery_key(Objective.t()) :: String.t()
  def completion_delivery_key(%Objective{fanout_role: "parent"} = fanout) do
    delivery_key(fanout.id, :completion, event_key: @completion_event_key)
  end

  defp completion_body(fanout) do
    fanout
    |> Fanout.report()
    |> Fanout.format_report()
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
