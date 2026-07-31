defmodule AllbertAssist.Conversations.Corpus do
  @moduledoc """
  Typed, policy-aware read boundary over canonical conversation rows.

  The module is deliberately a plain context rather than a GenServer: canonical
  ordering and authorization are Repo/Settings reads, and state-machine
  lifecycle would add no useful successor-agent or supervision behavior.
  """

  import Ecto.Query

  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.CorpusControl
  alias AllbertAssist.Conversations.CrossChannelIdentityLink
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @default_page_limit 200
  @max_page_limit 500
  @max_rehydrate_refs 100
  @context_each_side 4
  @context_max_messages 9
  @context_max_bytes 32_768
  @local_surfaces ~w[cli live_view web tui]
  @consumers [:memory, :search]
  @base_scopes [:local_operator, :mapped_operator_dm]
  @all_scopes [:local_operator, :mapped_operator_dm, :e2ee_operator]

  defmodule Snapshot do
    @moduledoc false
    @enforce_keys [:operator_id, :policy, :high_water, :eligibility_epoch, :binding]
    defstruct schema_version: 1,
              operator_id: nil,
              policy: nil,
              high_water: nil,
              eligibility_epoch: 0,
              binding: nil

    @type t :: %__MODULE__{
            schema_version: 1,
            operator_id: String.t(),
            policy: map(),
            high_water: {DateTime.t(), String.t()} | nil,
            eligibility_epoch: non_neg_integer(),
            binding: String.t()
          }
  end

  defmodule Cursor do
    @moduledoc false
    @enforce_keys [:snapshot_binding, :inserted_at, :source_id]
    defstruct schema_version: 1,
              snapshot_binding: nil,
              inserted_at: nil,
              source_id: nil

    @type t :: %__MODULE__{
            schema_version: 1,
            snapshot_binding: String.t(),
            inserted_at: DateTime.t(),
            source_id: String.t()
          }
  end

  @type policy :: %{
          consumer: :memory | :search,
          origin_scope: :local_operator | :mapped_operator_dm,
          e2ee?: boolean()
        }

  @type unavailable_reason ::
          :missing
          | :deleted
          | :ineligible
          | :scope_denied
          | :digest_mismatch
          | :legacy_principal_unverified
          | :legacy_origin_unverified

  @doc "Capture one inclusive high-water and consumer eligibility epoch."
  @spec snapshot(String.t(), policy()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot(operator_id, source_policy) when is_binary(operator_id) do
    with {:ok, policy} <- normalize_policy(source_policy),
         :ok <- authorize_policy(policy) do
      high_water = high_water(operator_id)
      epoch = eligibility_epoch(policy.consumer)
      binding = snapshot_binding(operator_id, policy, high_water, epoch)

      {:ok,
       %Snapshot{
         operator_id: operator_id,
         policy: policy,
         high_water: high_water,
         eligibility_epoch: epoch,
         binding: binding
       }}
    end
  end

  def snapshot(_operator_id, _source_policy), do: {:error, :invalid_operator}

  @doc "Read one stable canonical keyset page and return the last scanned cursor."
  @spec page(Snapshot.t(), Cursor.t() | nil, pos_integer()) ::
          {:ok, %{items: [SourceEnvelope.t()], cursor: Cursor.t() | nil, exhausted?: boolean()}}
          | {:error, term()}
  def page(snapshot, cursor \\ nil, limit \\ @default_page_limit)

  def page(%Snapshot{} = snapshot, cursor, limit)
      when is_integer(limit) and limit > 0 and limit <= @max_page_limit do
    with :ok <- validate_cursor(snapshot, cursor),
         :ok <- authorize_policy(snapshot.policy),
         :ok <- validate_snapshot_epoch(snapshot) do
      rows = page_rows(snapshot, cursor, limit)

      items =
        rows
        |> Enum.map(&envelope_for(&1, snapshot.operator_id, snapshot.policy))
        |> Enum.flat_map(fn
          {:ok, envelope} -> [envelope]
          {:error, _reason} -> []
        end)

      with :ok <- authorize_policy(snapshot.policy),
           :ok <- validate_snapshot_epoch(snapshot) do
        {:ok,
         %{
           items: items,
           cursor: next_cursor(snapshot, List.last(rows)),
           exhausted?: length(rows) < limit
         }}
      end
    end
  end

  def page(%Snapshot{}, _cursor, _limit), do: {:error, :invalid_page_limit}
  def page(_snapshot, _cursor, _limit), do: {:error, :invalid_snapshot}

  @doc "Read one snapshot page after a content-free prior high-water position."
  @spec page_after(Snapshot.t(), map() | nil, pos_integer()) ::
          {:ok, %{items: [SourceEnvelope.t()], cursor: Cursor.t() | nil, exhausted?: boolean()}}
          | {:error, term()}
  def page_after(%Snapshot{} = snapshot, watermark, limit) do
    with {:ok, cursor} <- incremental_cursor(snapshot, watermark) do
      page(snapshot, cursor, limit)
    end
  end

  defp incremental_cursor(_snapshot, nil), do: {:ok, nil}

  defp incremental_cursor(snapshot, %{
         inserted_at: %DateTime{} = inserted_at,
         source_id: source_id
       })
       when is_binary(source_id) and source_id != "" do
    {:ok,
     %Cursor{
       snapshot_binding: snapshot.binding,
       inserted_at: inserted_at,
       source_id: source_id
     }}
  end

  defp incremental_cursor(_snapshot, _watermark), do: {:error, :invalid_cursor}

  @doc "Re-read refs in request order and enforce current policy/scope/digest."
  @spec rehydrate_authorized(String.t(), [map() | String.t()], policy() | map()) ::
          {:ok, [{:ok, SourceEnvelope.t()} | {:error, unavailable_reason()}]}
          | {:error, term()}
  def rehydrate_authorized(operator_id, refs, scope)
      when is_binary(operator_id) and is_list(refs) and length(refs) <= @max_rehydrate_refs do
    with :ok <- unique_refs(refs),
         {:ok, policy} <- normalize_policy(scope),
         :ok <- authorize_policy(policy) do
      messages = load_messages(refs)
      results = Enum.map(refs, &rehydrate_one(messages, operator_id, &1, policy, scope))
      {:ok, results}
    end
  end

  def rehydrate_authorized(_operator_id, refs, _scope) when is_list(refs),
    do: {:error, :too_many_rehydrate_refs}

  def rehydrate_authorized(_operator_id, _refs, _scope), do: {:error, :invalid_refs}

  @doc "Compatibility spelling for the frozen batch rehydration contract."
  def rehydrate_and_authorize(operator_id, refs, scope),
    do: rehydrate_authorized(operator_id, refs, scope)

  @doc "Return bounded same-thread context around one currently authorized source."
  @spec conversation_context(String.t(), String.t(), policy()) ::
          {:ok, %{messages: [SourceEnvelope.t()], truncated: boolean()}} | {:error, term()}
  def conversation_context(operator_id, source_id, policy) do
    with {:ok, normalized} <- normalize_policy(policy),
         :ok <- authorize_policy(normalized),
         %Message{} = source <- Repo.get(Message, source_id),
         true <- source.user_id == operator_id,
         {:ok, _source_envelope} <- envelope_for(source, operator_id, normalized),
         :ok <- context_source_fits(source) do
      {rows, window_truncated?} = context_rows(source)

      envelopes =
        rows
        |> Enum.map(&context_envelope_for(&1, operator_id, normalized))
        |> Enum.flat_map(fn
          {:ok, envelope} -> [envelope]
          {:error, _reason} -> []
        end)

      {bounded, budget_truncated?} = bound_context(envelopes, source_id)
      {:ok, %{messages: bounded, truncated: window_truncated? or budget_truncated?}}
    else
      nil -> {:error, :missing}
      false -> {:error, :scope_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Change one consumer origin grant and advance only that consumer epoch."
  @spec set_origin_grant(:memory | :search, atom(), boolean(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def set_origin_grant(consumer, scope, granted?, context \\ %{})

  def set_origin_grant(consumer, scope, granted?, context)
      when consumer in @consumers and scope in @all_scopes and is_boolean(granted?) do
    key = grant_key(consumer)
    context = Map.put(context, skip_policy_reconcile_key(consumer), true)

    with {:ok, current} <- Settings.get(key),
         updated <- update_grants(current, Atom.to_string(scope), granted?),
         {:ok, _setting} <- Settings.put(key, updated, context),
         {:ok, epoch} <- bump_eligibility_epoch(consumer),
         :ok <- kick_consumer_reconcile(consumer) do
      {:ok, epoch}
    end
  end

  def set_origin_grant(_consumer, _scope, _granted?, _context),
    do: {:error, :invalid_origin_grant}

  @doc "Advance canonical eligibility for both consumers or one consumer."
  @spec bump_eligibility_epoch(:memory | :search | :all) ::
          {:ok, non_neg_integer() | map()} | {:error, term()}
  def bump_eligibility_epoch(:all) do
    Repo.transaction(fn ->
      Map.new(@consumers, &{&1, bump_epoch!(&1)})
    end)
  end

  def bump_eligibility_epoch(consumer) when consumer in @consumers do
    Repo.transaction(fn -> bump_epoch!(consumer) end)
  end

  def bump_eligibility_epoch(_consumer), do: {:error, :invalid_consumer}

  @doc "Return the current durable consumer eligibility epoch."
  def eligibility_epoch(consumer) when consumer in @consumers do
    case Repo.get(CorpusControl, Atom.to_string(consumer)) do
      %CorpusControl{eligibility_epoch: epoch} -> epoch
      nil -> 0
    end
  end

  defp high_water(operator_id) do
    Message
    |> where([message], message.user_id == ^operator_id)
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> select([message], {message.inserted_at, message.id})
    |> limit(1)
    |> Repo.one()
  end

  defp page_rows(%Snapshot{high_water: nil}, _cursor, _limit), do: []

  defp page_rows(snapshot, cursor, limit) do
    {high_at, high_id} = snapshot.high_water

    Message
    |> where([message], message.user_id == ^snapshot.operator_id)
    |> where(
      [message],
      message.inserted_at < ^high_at or
        (message.inserted_at == ^high_at and message.id <= ^high_id)
    )
    |> after_cursor(cursor)
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload([:thread, :origin_thread_ref])
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %Cursor{inserted_at: inserted_at, source_id: source_id}) do
    where(
      query,
      [message],
      message.inserted_at > ^inserted_at or
        (message.inserted_at == ^inserted_at and message.id > ^source_id)
    )
  end

  defp next_cursor(_snapshot, nil), do: nil

  defp next_cursor(snapshot, message) do
    %Cursor{
      snapshot_binding: snapshot.binding,
      inserted_at: message.inserted_at,
      source_id: message.id
    }
  end

  defp validate_cursor(_snapshot, nil), do: :ok

  defp validate_cursor(snapshot, %Cursor{snapshot_binding: binding}) do
    if binding == snapshot.binding, do: :ok, else: {:error, :cursor_snapshot_mismatch}
  end

  defp validate_cursor(_snapshot, _cursor), do: {:error, :invalid_cursor}

  defp validate_snapshot_epoch(snapshot) do
    if eligibility_epoch(snapshot.policy.consumer) == snapshot.eligibility_epoch,
      do: :ok,
      else: {:error, :eligibility_changed}
  end

  defp snapshot_binding(operator_id, policy, high_water, epoch) do
    :crypto.hash(:sha256, :erlang.term_to_binary({1, operator_id, policy, high_water, epoch}))
    |> Base.url_encode64(padding: false)
  end

  defp envelope_for(%Message{} = message, operator_id, policy) do
    envelope_for(message, operator_id, policy, :source)
  end

  defp context_envelope_for(%Message{} = message, operator_id, policy) do
    envelope_for(message, operator_id, policy, :context)
  end

  defp envelope_for(%Message{} = message, operator_id, policy, mode) do
    with {:ok, message} <- ensure_origin_evidence(message, policy),
         message <- Repo.preload(message, [:thread, :origin_thread_ref]),
         true <- message.user_id == operator_id || {:error, :scope_denied},
         {:ok, origin} <- verified_origin(message, policy),
         :ok <- consumer_author(message, policy, mode) do
      {:ok,
       %SourceEnvelope{
         source_type: :conversation,
         source_id: message.id,
         thread_id: message.thread_id,
         operator_id: operator_id,
         user_id: message.user_id,
         principal_digest: origin.principal_digest,
         role: message.role,
         author: author(message.role),
         trust: :private_operator,
         origin_scope: origin.origin_scope,
         origin_overlays: origin.origin_overlays,
         surface: origin.surface,
         thread_kind: message.thread.kind,
         content: message.content,
         content_digest: content_digest(message.content),
         inserted_at: message.inserted_at,
         source_version: 1,
         origin: origin.origin,
         trace_refs: trace_refs(message)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_origin_evidence(
         %Message{origin_thread_ref_id: nil, role: "user"} = message,
         %{origin_scope: :mapped_operator_dm}
       ) do
    backfill_legacy_remote_origin(message)
  end

  defp ensure_origin_evidence(message, _policy), do: {:ok, message}

  defp backfill_legacy_remote_origin(message) do
    case Repo.transaction(fn -> backfill_legacy_remote_origin!(message) end, mode: :immediate) do
      {:ok, %Message{} = updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.ConstraintError -> {:error, :legacy_principal_unverified}
  end

  defp backfill_legacy_remote_origin!(message) do
    current = Repo.get!(Message, message.id)

    if current.origin_thread_ref_id, do: current, else: apply_legacy_origin!(current)
  end

  defp apply_legacy_origin!(message) do
    refs =
      ConversationMessageRef
      |> where([ref], ref.canonical_message_id == ^message.id)
      |> order_by([ref], asc: ref.id)
      |> Repo.all()

    with {:ok, thread_ref} <- exact_legacy_thread_ref(message, refs),
         [principal_digest] <-
           current_principal_digests(message.user_id, thread_ref) |> Enum.uniq() do
      persist_legacy_origin!(message, thread_ref, principal_digest)
    else
      _other -> Repo.rollback(:legacy_principal_unverified)
    end
  end

  defp persist_legacy_origin!(message, thread_ref, principal_digest) do
    message
    |> Message.changeset(%{
      origin_thread_ref_id: thread_ref.id,
      origin_principal_digest: principal_digest,
      principal_normalizer_version: ChannelThread.principal_normalizer_version()
    })
    |> Repo.update!()
    |> tap(fn _updated ->
      from(ref in ConversationMessageRef,
        where: ref.canonical_message_id == ^message.id and is_nil(ref.thread_channel_ref_id)
      )
      |> Repo.update_all(set: [thread_channel_ref_id: thread_ref.id])
    end)
  end

  defp exact_legacy_thread_ref(_message, []),
    do: {:error, :legacy_principal_unverified}

  defp exact_legacy_thread_ref(message, refs) do
    candidate_lists = Enum.map(refs, &matching_thread_refs(message, &1))

    if Enum.all?(candidate_lists, &(length(&1) == 1)) do
      case candidate_lists |> List.flatten() |> Enum.uniq_by(& &1.id) do
        [thread_ref] -> {:ok, thread_ref}
        _other -> {:error, :legacy_principal_unverified}
      end
    else
      {:error, :legacy_principal_unverified}
    end
  end

  defp matching_thread_refs(message, ref) do
    ThreadChannelRef
    |> where(
      [thread_ref],
      thread_ref.canonical_thread_id == ^message.thread_id and
        thread_ref.owner_scope == ^ref.owner_scope and thread_ref.channel == ^ref.channel and
        thread_ref.receiver_account_ref == ^ref.receiver_account_ref and
        thread_ref.trust_class == ^ref.trust_class and thread_ref.trust_class != "local"
    )
    |> Repo.all()
  end

  defp verified_origin(%Message{origin_thread_ref: nil} = message, policy) do
    if local_surface?(message) and policy.origin_scope == :local_operator do
      {:ok,
       %{
         principal_digest: ChannelThread.principal_digest(message.user_id),
         origin_scope: :local_operator,
         origin_overlays: [],
         surface: local_surface(message),
         origin: nil
       }}
    else
      legacy_origin_error(message, policy)
    end
  end

  defp verified_origin(%Message{origin_thread_ref: %ThreadChannelRef{} = ref} = message, policy) do
    cond do
      ref.trust_class == "local" ->
        verify_local_origin(message, ref, policy)

      message.role == "assistant" and is_nil(message.origin_principal_digest) ->
        {:error, :legacy_origin_unverified}

      true ->
        verify_remote_origin(message, ref, policy)
    end
  end

  defp verify_local_origin(message, ref, policy) do
    expected = ChannelThread.principal_digest(message.user_id)

    if policy.origin_scope == :local_operator and message.origin_principal_digest == expected and
         message.principal_normalizer_version == ChannelThread.principal_normalizer_version() do
      {:ok,
       %{
         principal_digest: expected,
         origin_scope: :local_operator,
         origin_overlays: [],
         surface: ref.channel,
         origin: nil
       }}
    else
      {:error, :scope_denied}
    end
  end

  defp verify_remote_origin(message, ref, policy) do
    e2ee? = ref.trust_class == "e2ee_origin"

    cond do
      ref.conversation_scope != "direct" ->
        {:error, :scope_denied}

      policy.origin_scope != :mapped_operator_dm ->
        {:error, :scope_denied}

      e2ee? and not policy.e2ee? ->
        {:error, :scope_denied}

      message.principal_normalizer_version != ChannelThread.principal_normalizer_version() ->
        {:error, :legacy_principal_unverified}

      current_principal_matches?(message, ref) ->
        {:ok,
         %{
           principal_digest: message.origin_principal_digest,
           origin_scope: :mapped_operator_dm,
           origin_overlays: if(e2ee?, do: [:e2ee_operator], else: []),
           surface: ref.channel,
           origin: %{
             thread_channel_ref_id: to_string(ref.id),
             owner_scope: ref.owner_scope,
             channel: ref.channel,
             receiver_account_ref: ref.receiver_account_ref,
             provider_thread_key: ref.provider_thread_key,
             origin_principal_digest: message.origin_principal_digest,
             principal_normalizer_version: message.principal_normalizer_version
           }
         }}

      true ->
        {:error, :legacy_principal_unverified}
    end
  end

  defp current_principal_matches?(message, ref) do
    current_principal_digests(message.user_id, ref)
    |> Enum.uniq()
    |> case do
      [digest] -> digest == message.origin_principal_digest
      _other -> false
    end
  end

  defp current_principal_digests(user_id, ref) do
    settings_identity_digests(user_id, ref) ++ linked_identity_digests(user_id, ref)
  end

  defp settings_identity_digests(user_id, ref) do
    case Settings.get("channels.#{ref.channel}.identity_map") do
      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.filter(fn entry ->
          map_field(entry, "enabled", true) != false and
            normalize_string(map_field(entry, "user_id")) == normalize_string(user_id)
        end)
        |> Enum.map(&ChannelThread.principal_digest(map_field(&1, "external_user_id")))

      _other ->
        []
    end
  end

  defp linked_identity_digests(user_id, ref) do
    CrossChannelIdentityLink
    |> where(
      [link],
      link.user_id == ^user_id and link.owner_scope == ^ref.owner_scope and
        link.channel == ^ref.channel and link.receiver_account_ref == ^ref.receiver_account_ref
    )
    |> select([link], link.external_user_id)
    |> Repo.all()
    |> Enum.map(&ChannelThread.principal_digest/1)
  end

  defp legacy_origin_error(%Message{role: "assistant"}, %{origin_scope: :mapped_operator_dm}),
    do: {:error, :legacy_origin_unverified}

  defp legacy_origin_error(_message, _policy), do: {:error, :legacy_principal_unverified}

  defp consumer_author(%Message{role: "assistant"}, %{consumer: :memory}),
    do: {:error, :ineligible}

  defp consumer_author(%Message{} = message, %{consumer: :search}) do
    if map_field(message.metadata, "content_kind") == "search_result_render",
      do: {:error, :ineligible},
      else: :ok
  end

  defp consumer_author(_message, _policy), do: :ok

  defp consumer_author(_message, %{consumer: :memory}, :context), do: :ok
  defp consumer_author(message, policy, _mode), do: consumer_author(message, policy)

  defp load_messages(refs) do
    ids = Enum.map(refs, &elem(ref_identity(&1), 0))

    Message
    |> where([message], message.id in ^ids)
    |> preload([:thread, :origin_thread_ref])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp rehydrate_one(messages, operator_id, ref, policy, scope) do
    {source_id, expected_digest} = ref_identity(ref)

    case Map.get(messages, source_id) do
      nil ->
        {:error, :missing}

      %Message{} = message ->
        with {:ok, envelope} <- envelope_for(message, operator_id, policy),
             :ok <- match_digest(expected_digest, envelope.content_digest),
             :ok <- match_scope(envelope, scope) do
          {:ok, envelope}
        end
    end
  end

  defp match_digest(nil, _actual), do: :ok
  defp match_digest(actual, actual), do: :ok
  defp match_digest(_expected, _actual), do: {:error, :digest_mismatch}

  defp match_scope(envelope, scope) when is_map(scope) do
    required_thread = map_field(scope, "thread_id")
    required_origin = map_field(scope, "origin")

    cond do
      required_thread && envelope.thread_id != required_thread ->
        {:error, :scope_denied}

      is_map(required_origin) and not same_origin?(envelope.origin, required_origin) ->
        {:error, :scope_denied}

      true ->
        :ok
    end
  end

  defp match_scope(_envelope, _scope), do: :ok

  defp same_origin?(nil, _required), do: false

  defp same_origin?(origin, required) do
    Enum.all?(~w[owner_scope channel receiver_account_ref provider_thread_key]a, fn key ->
      Map.get(origin, key) == map_field(required, Atom.to_string(key))
    end)
  end

  defp ref_identity(ref) when is_binary(ref), do: {ref, nil}

  defp ref_identity(ref) when is_map(ref) do
    {map_field(ref, "source_id") || map_field(ref, "id"), map_field(ref, "content_digest")}
  end

  defp context_rows(source) do
    before_rows = context_before(source)

    before =
      before_rows
      |> Enum.take(@context_each_side)
      |> Enum.reverse()

    after_rows = context_after(source)

    rows =
      before ++ [source] ++ Enum.take(after_rows, @context_each_side)

    {Repo.preload(rows, [:thread, :origin_thread_ref]),
     length(before_rows) > @context_each_side or length(after_rows) > @context_each_side}
  end

  defp context_before(source) do
    Message
    |> where(
      [message],
      message.thread_id == ^source.thread_id and message.user_id == ^source.user_id and
        (message.inserted_at < ^source.inserted_at or
           (message.inserted_at == ^source.inserted_at and message.id < ^source.id))
    )
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> limit(@context_each_side + 1)
    |> Repo.all()
  end

  defp context_after(source) do
    Message
    |> where(
      [message],
      message.thread_id == ^source.thread_id and message.user_id == ^source.user_id and
        (message.inserted_at > ^source.inserted_at or
           (message.inserted_at == ^source.inserted_at and message.id > ^source.id))
    )
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> limit(@context_each_side + 1)
    |> Repo.all()
  end

  defp bound_context(envelopes, source_id) do
    envelopes = Enum.take(envelopes, @context_max_messages)
    original_count = length(envelopes)
    original_bytes = total_bytes(envelopes)
    bounded = drop_farthest_until_bounded(envelopes, source_id)
    {bounded, length(bounded) < original_count or original_bytes > @context_max_bytes}
  end

  defp drop_farthest_until_bounded(envelopes, source_id) do
    if total_bytes(envelopes) <= @context_max_bytes do
      envelopes
    else
      source_index = Enum.find_index(envelopes, &(&1.source_id == source_id)) || 0

      {drop_index, _distance} =
        envelopes
        |> Enum.with_index()
        |> Enum.reject(fn {_envelope, index} -> index == source_index end)
        |> Enum.map(fn {_envelope, index} -> {index, abs(index - source_index)} end)
        |> Enum.max_by(fn {index, distance} -> {distance, index} end, fn -> {nil, 0} end)

      if is_nil(drop_index) do
        envelopes
      else
        envelopes
        |> List.delete_at(drop_index)
        |> drop_farthest_until_bounded(source_id)
      end
    end
  end

  defp context_source_fits(source) do
    if byte_size(source.content) <= @context_max_bytes,
      do: :ok,
      else: {:error, :source_context_too_large}
  end

  defp total_bytes(envelopes), do: Enum.sum(Enum.map(envelopes, &byte_size(&1.content)))

  defp normalize_policy(policy) when is_map(policy) do
    consumer = normalize_atom(map_field(policy, "consumer"), @consumers)
    origin_scope = normalize_atom(map_field(policy, "origin_scope"), @base_scopes)
    e2ee? = map_field(policy, "e2ee?", map_field(policy, "e2ee", false))

    if consumer && origin_scope && is_boolean(e2ee?) do
      {:ok, %{consumer: consumer, origin_scope: origin_scope, e2ee?: e2ee?}}
    else
      {:error, :invalid_source_policy}
    end
  end

  defp normalize_policy(_policy), do: {:error, :invalid_source_policy}

  defp authorize_policy(policy) do
    enabled? = setting_enabled?(policy.consumer)
    grants = origin_grants(policy.consumer)
    base = Atom.to_string(policy.origin_scope)

    cond do
      not enabled? -> {:error, :consumer_disabled}
      base not in grants -> {:error, :origin_grant_required}
      policy.e2ee? and "e2ee_operator" not in grants -> {:error, :e2ee_grant_required}
      true -> :ok
    end
  end

  defp setting_enabled?(:memory), do: setting("memory.consolidation.enabled", false)
  defp setting_enabled?(:search), do: setting("search.enabled", true)

  defp origin_grants(consumer), do: setting(grant_key(consumer), default_grants(consumer))
  defp default_grants(:memory), do: []
  defp default_grants(:search), do: ["local_operator"]
  defp grant_key(:memory), do: "memory.collection.origin_grants"
  defp grant_key(:search), do: "search.origin_grants"

  defp kick_consumer_reconcile(:memory) do
    case Managed.reconcile("local") do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp kick_consumer_reconcile(:search) do
    Enum.each(["search-rebuild", "search-index"], fn identity ->
      _ = Managed.kick(identity, "local")
    end)

    :ok
  end

  defp skip_policy_reconcile_key(:memory), do: :skip_memory_policy_reconcile?
  defp skip_policy_reconcile_key(:search), do: :skip_search_policy_reconcile?

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp update_grants(current, scope, true), do: Enum.sort(Enum.uniq([scope | current]))
  defp update_grants(current, scope, false), do: Enum.reject(current, &(&1 == scope))

  defp bump_epoch!(consumer) do
    key = Atom.to_string(consumer)

    case Repo.get(CorpusControl, key) do
      nil ->
        %CorpusControl{}
        |> CorpusControl.changeset(%{consumer: key, eligibility_epoch: 1})
        |> Repo.insert!()
        |> Map.fetch!(:eligibility_epoch)

      control ->
        control
        |> CorpusControl.changeset(%{eligibility_epoch: control.eligibility_epoch + 1})
        |> Repo.update!()
        |> Map.fetch!(:eligibility_epoch)
    end
  end

  defp unique_refs(refs) do
    ids = Enum.map(refs, &elem(ref_identity(&1), 0))

    if Enum.all?(ids, &is_binary/1) and ids == Enum.uniq(ids),
      do: :ok,
      else: {:error, :invalid_refs}
  end

  defp content_digest(content) do
    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  defp author("user"), do: :operator
  defp author("assistant"), do: :assistant

  defp trace_refs(message) do
    [message.trace_id, message.input_signal_id, message.response_signal_id]
    |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= 128))
    |> Enum.take(4)
  end

  defp local_surface?(message), do: local_surface(message) in @local_surfaces

  defp local_surface(message) do
    message.metadata
    |> map_field("channel", map_field(message.metadata, "local_surface", "unknown"))
    |> normalize_string()
  end

  defp map_field(map, key, default \\ nil)

  defp map_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end

  defp map_field(_map, _key, default), do: default

  defp normalize_atom(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize_atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp normalize_atom(_value, _allowed), do: nil
  defp normalize_string(nil), do: ""
  defp normalize_string(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
