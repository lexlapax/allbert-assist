defmodule AllbertAssist.Conversations.Deletion do
  @moduledoc """
  Exact preview and canonical commit boundary for conversation deletion.

  This is a plain domain context: the canonical Repo transaction is the state
  machine, and adding a process would provide no authority or durability.
  Separately governed records are counted and retained; only conversation-owned
  rows are deleted.
  """

  import Ecto.Query

  alias AllbertAssist.Artifacts.ThreadLink
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.Workspace.Canvas.Tile
  alias AllbertAssist.Workspace.Ephemeral.Surface

  @domain "allbert.conversations.delete-preview.v1"
  @key_version 1
  @binding_prefix "hmac-sha256:"
  @digest_pattern ~r/^sha256:[0-9a-f]{64}$/
  @target_kinds [:message, :thread]
  @active_job_statuses ~w[active blocked]
  @active_objective_statuses ~w[open running blocked]
  @nonterminal_delivery_states ~w[reserved sending uncertain]
  @blocker_keys ~w[active_jobs active_objectives nonterminal_fanout_deliveries open_workspace_states]a
  @survivor_keys ~w[historical_jobs historical_runs historical_objectives stocksage_rows channel_events channel_deliveries artifact_links traces closed_workspace_states]a

  @type target_kind :: :message | :thread

  @doc "Build an HMAC-bound, content-free preview for one owned target."
  @spec preview(String.t(), target_kind(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def preview(user_id, target_kind, target_id, expected_digest \\ nil) do
    with {:ok, request} <- normalize_request(user_id, target_kind, target_id, expected_digest),
         {:ok, resolved} <- resolve_target(request),
         :ok <- match_expected_digest(resolved.target_digest, request.expected_digest),
         :ok <- preview_blockers(resolved.blocker_counts),
         {:ok, hmac} <- KeyCustody.system_hmac(@domain, binding_fields(resolved), @key_version) do
      preview = preview_dto(resolved, encode_binding(hmac.tag))

      {:ok,
       %{
         preview: preview,
         key_ref: hmac.key_ref,
         key_version: hmac.key_version
       }}
    end
  end

  @doc "Re-resolve and delete the exact approved cascade in one immediate transaction."
  @spec delete_approved(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def delete_approved(user_id, params) when is_map(params) do
    with {:ok, request} <- approved_request(user_id, params) do
      case Repo.transaction(fn -> delete_in_transaction(request) end, mode: :immediate) do
        {:ok, result} ->
          reconcile_after_commit(user_id, result.outcome)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_approved(_user_id, _params), do: {:error, :invalid_params}

  defp delete_in_transaction(request) do
    case resolve_target(request) do
      {:ok, resolved} ->
        with :ok <- reject_blockers(resolved.blocker_counts),
             {:ok, tag} <- decode_binding(request.preview_binding),
             {:ok, true} <-
               KeyCustody.verify_system_hmac(
                 @domain,
                 binding_fields(resolved),
                 tag,
                 request.key_ref,
                 request.key_version
               ) do
          delete_resolved(resolved)
        else
          {:ok, false} ->
            Repo.rollback(:stale)

          {:error, :live_dependency} ->
            Repo.rollback({:live_dependency, nonzero_blockers(resolved.blocker_counts)})

          {:error, _reason} ->
            Repo.rollback(:stale)
        end

      {:error, :not_found} ->
        already_deleted_result(request)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp resolve_target(%{target_kind: :message} = request) do
    case Repo.get(Message, request.target_id) do
      nil -> {:error, :not_found}
      %Message{user_id: user_id} when user_id != request.user_id -> {:error, :unauthorized}
      %Message{} = message -> {:ok, resolve_message(message)}
    end
  end

  defp resolve_target(%{target_kind: :thread} = request) do
    case Repo.get(Thread, request.target_id) do
      nil -> {:error, :not_found}
      %Thread{user_id: user_id} when user_id != request.user_id -> {:error, :unauthorized}
      %Thread{} = thread -> {:ok, resolve_thread(thread)}
    end
  end

  defp resolve_message(message) do
    thread = Repo.get!(Thread, message.thread_id)
    message_refs = message_refs([message.id])
    counts = inventory(:message, thread, [message], [])

    %{
      target_kind: :message,
      target_id: message.id,
      user_id: message.user_id,
      thread: thread,
      messages: [message],
      thread_refs: [],
      message_refs: message_refs,
      message_count: 1,
      reference_count: length(message_refs),
      retained_thread_title?: true,
      blocker_counts: zero_counts(@blocker_keys),
      survivor_counts: counts.survivors,
      target_digest: content_digest(message.content)
    }
  end

  defp resolve_thread(thread) do
    messages =
      Message
      |> where([message], message.thread_id == ^thread.id and message.user_id == ^thread.user_id)
      |> order_by([message], asc: message.inserted_at, asc: message.id)
      |> Repo.all()

    message_refs = message_refs(Enum.map(messages, & &1.id))

    thread_refs =
      ThreadChannelRef
      |> where([ref], ref.canonical_thread_id == ^thread.id)
      |> order_by([ref], asc: ref.id)
      |> Repo.all()

    counts = inventory(:thread, thread, messages, thread_refs)

    %{
      target_kind: :thread,
      target_id: thread.id,
      user_id: thread.user_id,
      thread: thread,
      messages: messages,
      thread_refs: thread_refs,
      message_refs: message_refs,
      message_count: length(messages),
      reference_count: length(message_refs) + length(thread_refs),
      retained_thread_title?: false,
      blocker_counts: counts.blockers,
      survivor_counts: counts.survivors,
      target_digest: aggregate_digest(Enum.map(messages, &content_digest(&1.content)))
    }
  end

  defp message_refs([]), do: []

  defp message_refs(message_ids) do
    ConversationMessageRef
    |> where([ref], ref.canonical_message_id in ^message_ids)
    |> order_by([ref], asc: ref.id)
    |> Repo.all()
  end

  defp inventory(:message, thread, [message], _thread_refs) do
    survivors =
      zero_counts(@survivor_keys)
      |> Map.put(
        :channel_events,
        count(Event, thread_id: thread.id, receipt_message_id: message.id)
      )
      |> Map.put(:artifact_links, count(ThreadLink, thread_id: thread.id, message_id: message.id))
      |> Map.put(:traces, if(present?(message.trace_id), do: 1, else: 0))

    %{blockers: zero_counts(@blocker_keys), survivors: survivors}
  end

  defp inventory(:thread, thread, messages, thread_refs) do
    thread_ref_ids = Enum.map(thread_refs, &to_string(&1.id))

    active_jobs =
      Job
      |> where(
        [job],
        job.user_id == ^thread.user_id and job.thread_id == ^thread.id and
          job.status in ^@active_job_statuses
      )
      |> Repo.aggregate(:count, :id)

    historical_jobs =
      Job
      |> where(
        [job],
        job.user_id == ^thread.user_id and job.thread_id == ^thread.id and
          job.status not in ^@active_job_statuses
      )
      |> Repo.aggregate(:count, :id)

    active_objectives =
      Objective
      |> where(
        [objective],
        objective.user_id == ^thread.user_id and objective.source_thread_id == ^thread.id and
          objective.status in ^@active_objective_statuses
      )
      |> Repo.aggregate(:count, :id)

    historical_objectives =
      Objective
      |> where(
        [objective],
        objective.user_id == ^thread.user_id and objective.source_thread_id == ^thread.id and
          objective.status not in ^@active_objective_statuses
      )
      |> Repo.aggregate(:count, :id)

    nonterminal_deliveries = delivery_count(thread_ref_ids, @nonterminal_delivery_states)
    channel_deliveries = delivery_count(thread_ref_ids, nil)
    {open_workspace, closed_workspace} = workspace_counts(thread)

    blockers = %{
      active_jobs: active_jobs,
      active_objectives: active_objectives,
      nonterminal_fanout_deliveries: nonterminal_deliveries,
      open_workspace_states: open_workspace
    }

    survivors = %{
      historical_jobs: historical_jobs,
      historical_runs: count(Run, user_id: thread.user_id, thread_id: thread.id),
      historical_objectives: historical_objectives,
      stocksage_rows: stocksage_count(thread.id),
      channel_events: count(Event, user_id: thread.user_id, thread_id: thread.id),
      channel_deliveries: channel_deliveries,
      artifact_links: count(ThreadLink, user_id: thread.user_id, thread_id: thread.id),
      traces:
        messages |> Enum.map(& &1.trace_id) |> Enum.filter(&present?/1) |> Enum.uniq() |> length(),
      closed_workspace_states: closed_workspace
    }

    %{blockers: blockers, survivors: survivors}
  end

  defp workspace_counts(thread) do
    open_ephemerals =
      Surface
      |> where(
        [surface],
        surface.user_id == ^thread.user_id and surface.thread_id == ^thread.id and
          is_nil(surface.dismissed_at)
      )
      |> Repo.aggregate(:count, :id)

    closed_ephemerals =
      Surface
      |> where(
        [surface],
        surface.user_id == ^thread.user_id and surface.thread_id == ^thread.id and
          not is_nil(surface.dismissed_at)
      )
      |> Repo.aggregate(:count, :id)

    open_tiles =
      Tile
      |> where(
        [tile],
        tile.user_id == ^thread.user_id and tile.thread_id == ^thread.id and
          is_nil(tile.deleted_at)
      )
      |> Repo.aggregate(:count, :id)

    closed_tiles =
      Tile
      |> where(
        [tile],
        tile.user_id == ^thread.user_id and tile.thread_id == ^thread.id and
          not is_nil(tile.deleted_at)
      )
      |> Repo.aggregate(:count, :id)

    {open_ephemerals + open_tiles, closed_ephemerals + closed_tiles}
  end

  defp delivery_count([], _states), do: 0

  defp delivery_count(thread_ref_ids, nil) do
    NotifyDelivery
    |> where([delivery], delivery.origin_thread_ref_id in ^thread_ref_ids)
    |> Repo.aggregate(:count, :id)
  end

  defp delivery_count(thread_ref_ids, states) do
    NotifyDelivery
    |> where(
      [delivery],
      delivery.origin_thread_ref_id in ^thread_ref_ids and delivery.state in ^states
    )
    |> Repo.aggregate(:count, :id)
  end

  defp stocksage_count(thread_id) do
    ["stocksage_analyses", "stocksage_analysis_queue"]
    |> Enum.filter(&table_exists?/1)
    |> Enum.map(&raw_thread_count(&1, thread_id))
    |> Enum.sum()
  end

  defp table_exists?(table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
        [table]
      )

    rows != []
  end

  defp raw_thread_count("stocksage_analyses", thread_id),
    do: raw_count("SELECT COUNT(*) FROM stocksage_analyses WHERE thread_id = ?", thread_id)

  defp raw_thread_count("stocksage_analysis_queue", thread_id),
    do: raw_count("SELECT COUNT(*) FROM stocksage_analysis_queue WHERE thread_id = ?", thread_id)

  defp raw_count(sql, thread_id) do
    %{rows: [[count]]} = Ecto.Adapters.SQL.query!(Repo, sql, [thread_id])
    count
  end

  defp count(schema, filters) do
    Enum.reduce(filters, schema, fn {field, value}, query ->
      where(query, [row], field(row, ^field) == ^value)
    end)
    |> Repo.aggregate(:count, :id)
  end

  defp binding_fields(resolved) do
    [
      "schema:1",
      "user:#{resolved.user_id}",
      "target_kind:#{resolved.target_kind}",
      "target_id:#{resolved.target_id}",
      thread_version(resolved.thread)
    ] ++
      Enum.map(resolved.messages, &message_version/1) ++
      Enum.map(resolved.thread_refs, &thread_ref_version/1) ++
      Enum.map(resolved.message_refs, &message_ref_version/1) ++
      count_fields("blocker", resolved.blocker_counts, @blocker_keys) ++
      count_fields("survivor", resolved.survivor_counts, @survivor_keys) ++
      ["disclosure_version:1"]
  end

  defp thread_version(thread) do
    Enum.join(
      [
        "thread",
        thread.id,
        timestamp(thread.inserted_at),
        timestamp(thread.updated_at),
        content_digest(thread.title),
        timestamp(thread.last_message_at)
      ],
      ":"
    )
  end

  defp message_version(message) do
    Enum.join(
      ["message", message.id, timestamp(message.inserted_at), content_digest(message.content)],
      ":"
    )
  end

  defp thread_ref_version(ref) do
    Enum.join(
      [
        "thread_ref",
        ref.id,
        timestamp(ref.updated_at),
        ref.owner_scope,
        ref.channel,
        ref.receiver_account_ref,
        ref.provider_thread_key,
        ref.trust_class,
        term_digest(ref.provider_thread_ref)
      ],
      ":"
    )
  end

  defp message_ref_version(ref) do
    Enum.join(
      [
        "message_ref",
        ref.id,
        timestamp(ref.updated_at),
        ref.owner_scope,
        ref.channel,
        ref.receiver_account_ref,
        ref.provider_message_id,
        ref.part_id,
        ref.direction,
        ref.trust_class,
        to_string(ref.thread_channel_ref_id || "")
      ],
      ":"
    )
  end

  defp count_fields(prefix, counts, keys) do
    Enum.map(keys, &"#{prefix}:#{&1}:#{Map.fetch!(counts, &1)}")
  end

  defp preview_dto(resolved, binding) do
    %{
      schema_version: 1,
      target_kind: resolved.target_kind,
      target_id: resolved.target_id,
      message_count: resolved.message_count,
      reference_count: resolved.reference_count,
      blocker_counts: resolved.blocker_counts,
      survivor_counts: resolved.survivor_counts,
      retained_thread_title?: resolved.retained_thread_title?,
      disclosure_version: 1,
      preview_binding: binding
    }
  end

  defp delete_resolved(%{target_kind: :message} = resolved) do
    {reference_count, _rows} =
      ConversationMessageRef
      |> where([ref], ref.canonical_message_id == ^resolved.target_id)
      |> Repo.delete_all()

    {1, _rows} =
      Message
      |> where(
        [message],
        message.id == ^resolved.target_id and message.user_id == ^resolved.user_id
      )
      |> Repo.delete_all()

    recompute_thread_recency(resolved.thread)
    bump_corpus!()

    result_dto(resolved, :deleted, 1, reference_count)
  end

  defp delete_resolved(%{target_kind: :thread} = resolved) do
    {1, _rows} =
      Thread
      |> where(
        [thread],
        thread.id == ^resolved.target_id and thread.user_id == ^resolved.user_id
      )
      |> Repo.delete_all()

    bump_corpus!()

    result_dto(
      resolved,
      :deleted,
      resolved.message_count,
      resolved.reference_count
    )
  end

  defp recompute_thread_recency(thread) do
    latest =
      Message
      |> where([message], message.thread_id == ^thread.id and message.user_id == ^thread.user_id)
      |> Repo.aggregate(:max, :inserted_at)

    thread
    |> Thread.last_message_changeset(latest || thread.inserted_at)
    |> Repo.update!()
  end

  defp result_dto(resolved, outcome, message_count, reference_count) do
    %{
      schema_version: 1,
      target_kind: resolved.target_kind,
      target_id: resolved.target_id,
      outcome: outcome,
      deleted_message_count: message_count,
      deleted_reference_count: reference_count,
      retained_thread_title?: resolved.retained_thread_title?,
      downstream_reconcile_required: true,
      disclosure_version: 1
    }
  end

  defp already_deleted_result(request) do
    %{
      schema_version: 1,
      target_kind: request.target_kind,
      target_id: request.target_id,
      outcome: :already_deleted,
      deleted_message_count: request.message_count,
      deleted_reference_count: request.reference_count,
      retained_thread_title?: request.retained_thread_title?,
      downstream_reconcile_required: true,
      disclosure_version: 1
    }
  end

  defp reconcile_after_commit(user_id, :already_deleted) do
    _epoch = Corpus.bump_eligibility_epoch(:all)
    _kick = Managed.kick("search-index", user_id)
    :ok
  end

  defp reconcile_after_commit(user_id, :deleted) do
    _kick = Managed.kick("search-index", user_id)
    :ok
  end

  defp bump_corpus! do
    case Corpus.bump_eligibility_epoch(:all) do
      {:ok, _epochs} -> :ok
      {:error, reason} -> Repo.rollback({:corpus_invalidation_failed, reason})
    end
  end

  defp reject_blockers(counts) do
    if Enum.any?(counts, fn {_key, count} -> count > 0 end),
      do: {:error, :live_dependency},
      else: :ok
  end

  defp preview_blockers(counts) do
    case reject_blockers(counts) do
      :ok -> :ok
      {:error, :live_dependency} -> {:error, {:live_dependency, nonzero_blockers(counts)}}
    end
  end

  defp nonzero_blockers(counts), do: Map.reject(counts, fn {_key, count} -> count == 0 end)

  defp normalize_request(user_id, target_kind, target_id, expected_digest) do
    target_kind = normalize_target_kind(target_kind)
    user_id = normalize_string(user_id)
    target_id = normalize_string(target_id)

    cond do
      target_kind not in @target_kinds ->
        {:error, :invalid_target_kind}

      user_id == "" ->
        {:error, :unauthorized}

      target_id == "" ->
        {:error, :missing_target_id}

      not is_nil(expected_digest) and not Regex.match?(@digest_pattern, expected_digest) ->
        {:error, :invalid_expected_digest}

      true ->
        {:ok,
         %{
           user_id: user_id,
           target_kind: target_kind,
           target_id: target_id,
           expected_digest: expected_digest
         }}
    end
  end

  defp approved_request(user_id, params) do
    with {:ok, request} <-
           normalize_request(
             user_id,
             field(params, :target_kind),
             field(params, :target_id),
             nil
           ),
         preview_binding when is_binary(preview_binding) <- field(params, :preview_binding),
         key_ref when is_binary(key_ref) <- field(params, :key_ref),
         key_version when is_integer(key_version) <- field(params, :key_version),
         message_count when is_integer(message_count) and message_count >= 0 <-
           field(params, :message_count),
         reference_count when is_integer(reference_count) and reference_count >= 0 <-
           field(params, :reference_count),
         retained_thread_title? when is_boolean(retained_thread_title?) <-
           field(params, :retained_thread_title?) do
      {:ok,
       Map.merge(request, %{
         preview_binding: preview_binding,
         key_ref: key_ref,
         key_version: key_version,
         message_count: message_count,
         reference_count: reference_count,
         retained_thread_title?: retained_thread_title?
       })}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_approved_preview}
    end
  end

  defp match_expected_digest(_actual, nil), do: :ok
  defp match_expected_digest(actual, actual), do: :ok
  defp match_expected_digest(_actual, _expected), do: {:error, :stale}

  defp encode_binding(tag), do: @binding_prefix <> Base.encode16(tag, case: :lower)

  defp decode_binding(@binding_prefix <> hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, tag} when byte_size(tag) == 32 -> {:ok, tag}
      _other -> {:error, :invalid_preview_binding}
    end
  end

  defp decode_binding(_binding), do: {:error, :invalid_preview_binding}

  defp aggregate_digest(digests), do: content_digest(Enum.join(digests, <<0>>))
  defp content_digest(value), do: "sha256:" <> raw_digest(to_string(value))
  defp term_digest(value), do: raw_digest(:erlang.term_to_binary(value))
  defp raw_digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(nil), do: ""
  defp timestamp(value), do: to_string(value)
  defp zero_counts(keys), do: Map.new(keys, &{&1, 0})
  defp present?(value), do: is_binary(value) and value != ""
  defp normalize_target_kind(value) when is_atom(value), do: value

  defp normalize_target_kind(value) when is_binary(value) do
    Enum.find(@target_kinds, &(Atom.to_string(&1) == value))
  end

  defp normalize_target_kind(_value), do: nil
  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
