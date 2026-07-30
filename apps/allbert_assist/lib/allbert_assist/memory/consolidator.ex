defmodule AllbertAssist.Memory.Consolidator do
  @moduledoc """
  Bounded Corpus-to-proposal collection for the managed consolidation job.

  This is a plain orchestration context, not a scheduler or process. Jobs owns
  cadence/admission; Corpus owns source authority; Extractor owns grounding;
  Proposals owns inert writes. Disabled or ungranted runs return before taking
  a Corpus snapshot.
  """

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Memory.ConsolidationControl
  alias AllbertAssist.Memory.Extractor
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @lookback_days 30
  @page_limit 200
  @run_proposal_cap 20
  @pending_cap 50

  @doc "Run one bounded local-only consolidation pass."
  def run(operator_id) when is_binary(operator_id) do
    policies = policies()

    cond do
      not setting("memory.consolidation.enabled", false) ->
        {:ok, no_op(:disabled)}

      Proposals.pending_count(operator_id) >= @pending_cap ->
        {:ok, no_op(:pending_cap_reached)}

      policies == [] ->
        {:ok, no_op(:origin_grant_required)}

      true ->
        run_enabled(operator_id, policies)
    end
  end

  def run(_operator_id), do: {:error, :invalid_operator}

  defp run_enabled(operator_id, policies) do
    run_id = Ecto.UUID.generate()
    initial = summary(run_id)

    result =
      Enum.reduce_while(policies, initial, &run_policy(&1, &2, operator_id, run_id))

    {:ok, Map.put(result, :pending_after, Proposals.pending_count(operator_id))}
  end

  defp run_policy(policy, acc, operator_id, run_id) do
    if acc.created >= @run_proposal_cap or
         Proposals.pending_count(operator_id) >= @pending_cap do
      {:halt, Map.put(acc, :stopped_reason, "cap_reached")}
    else
      scan_policy(operator_id, policy, run_id, @run_proposal_cap - acc.created)
      |> merge_policy_scan(acc)
    end
  end

  defp merge_policy_scan({:ok, policy_summary}, acc),
    do: {:cont, merge_summary(acc, policy_summary)}

  defp merge_policy_scan({:error, reason}, acc),
    do: {:halt, Map.put(acc, :stopped_reason, inspect(reason))}

  defp scan_policy(operator_id, policy, run_id, remaining_cap) do
    with {:ok, snapshot} <- Corpus.snapshot(operator_id, policy),
         control <- control(operator_id, policy),
         cursor <- cursor(snapshot, control),
         {:ok, page} <- Corpus.page(snapshot, cursor, @page_limit) do
      eligible = Enum.filter(page.items, &inside_lookback?/1)
      result = collect_page(eligible, run_id, remaining_cap)

      case persist_control(control, policy, page, result) do
        :ok ->
          {:ok, result |> Map.drop([:last_cursor]) |> Map.put(:scanned, length(page.items))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp collect_page(items, run_id, remaining_cap) do
    Enum.reduce_while(
      items,
      empty_policy_summary(),
      &collect_page_source(&1, &2, run_id, remaining_cap)
    )
  end

  defp collect_page_source(_source, acc, _run_id, remaining_cap)
       when acc.created >= remaining_cap,
       do: {:halt, Map.put(acc, :stopped_reason, "run_proposal_cap")}

  defp collect_page_source(source, acc, run_id, _remaining_cap) do
    collected = collect_source(source, run_id, Map.put(acc, :last_cursor, source_cursor(source)))

    if collected.stopped_reason,
      do: {:halt, collected},
      else: {:cont, collected}
  end

  defp collect_source(source, run_id, acc) do
    case Extractor.classify_source(source) do
      :ordinary ->
        collect_ordinary(source, run_id, acc)

      {:drop, :credential} ->
        Map.update!(acc, :secret_dropped, &(&1 + 1))

      {:drop, :financial_identifier} ->
        Map.update!(acc, :protected_dropped, &(&1 + 1))

      {:protected_review, classification, classifier_digest} ->
        collect_protected(source, run_id, acc, classification, classifier_digest)

      {:abstain, _reason} ->
        Map.update!(acc, :abstained, &(&1 + 1))
    end
  end

  defp collect_ordinary(source, run_id, acc) do
    with {:ok, context} <-
           Corpus.conversation_context(
             source.operator_id,
             source.source_id,
             %{consumer: :memory, origin_scope: source.origin_scope, e2ee?: e2ee?(source)}
           ),
         sources <- extraction_sources(context.messages, source),
         {:ok, extracted} <- Extractor.extract(sources),
         {:ok, result} <- Proposals.propose_extracted(extracted, run_id) do
      case result.outcome do
        :created -> Map.update!(acc, :created, &(&1 + 1))
        :existing -> Map.update!(acc, :deduplicated, &(&1 + 1))
      end
    else
      {:abstain, _reason} -> Map.update!(acc, :abstained, &(&1 + 1))
      {:error, :secret_filtered} -> Map.update!(acc, :secret_dropped, &(&1 + 1))
      {:error, :forgotten_value_suppressed} -> Map.update!(acc, :suppressed, &(&1 + 1))
      {:error, :unchanged_reject_suppressed} -> Map.update!(acc, :suppressed, &(&1 + 1))
      {:error, :pending_cap_reached} -> Map.put(acc, :stopped_reason, "pending_cap")
      {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
    end
  end

  defp collect_protected(source, run_id, acc, classification, classifier_digest) do
    case Proposals.propose_protected(source, %{
           classification: classification,
           classifier_digest: classifier_digest,
           category: "notes",
           namespace: "default",
           run_id: run_id,
           extractor_profile: "deterministic_protected_classifier_v1",
           extractor_version: 1
         }) do
      {:ok, %{outcome: :created}} ->
        acc
        |> Map.update!(:created, &(&1 + 1))
        |> Map.update!(:protected_routed, &(&1 + 1))

      {:ok, %{outcome: :existing}} ->
        Map.update!(acc, :deduplicated, &(&1 + 1))

      {:error, :pending_cap_reached} ->
        Map.put(acc, :stopped_reason, "pending_cap")

      {:error, _reason} ->
        Map.update!(acc, :failed, &(&1 + 1))
    end
  end

  defp extraction_sources(messages, source) do
    messages
    |> Enum.reject(&(&1.source_id == source.source_id))
    |> Enum.filter(&not_after?(&1, source))
    |> Kernel.++([source])
  end

  defp not_after?(candidate, source) do
    DateTime.compare(candidate.inserted_at, source.inserted_at) == :lt or
      (candidate.inserted_at == source.inserted_at and candidate.source_id < source.source_id)
  end

  defp control(operator_id, policy) do
    id = control_id(operator_id, policy)

    Repo.get(ConsolidationControl, id) ||
      %ConsolidationControl{
        id: id,
        operator_id: operator_id,
        origin_scope: Atom.to_string(policy.origin_scope),
        e2ee: policy.e2ee?,
        run_sequence: 0,
        last_run: %{}
      }
  end

  defp cursor(_snapshot, %ConsolidationControl{cursor_inserted_at: nil}), do: nil

  defp cursor(snapshot, control) do
    %Corpus.Cursor{
      snapshot_binding: snapshot.binding,
      inserted_at: control.cursor_inserted_at,
      source_id: control.cursor_source_id
    }
  end

  defp persist_control(control, policy, page, result) do
    {cursor_inserted_at, cursor_source_id} = next_cursor(page, result)

    attrs = %{
      id: control.id,
      operator_id: control.operator_id,
      origin_scope: Atom.to_string(policy.origin_scope),
      e2ee: policy.e2ee?,
      cursor_inserted_at: cursor_inserted_at,
      cursor_source_id: cursor_source_id,
      run_sequence: control.run_sequence + 1,
      last_run: content_free_summary(result, page)
    }

    control
    |> ConsolidationControl.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, _control} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp policies do
    grants = setting("memory.collection.origin_grants", [])

    [
      if("local_operator" in grants,
        do: %{consumer: :memory, origin_scope: :local_operator, e2ee?: false}
      ),
      if("mapped_operator_dm" in grants,
        do: %{
          consumer: :memory,
          origin_scope: :mapped_operator_dm,
          e2ee?: "e2ee_operator" in grants
        }
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp inside_lookback?(source) do
    cutoff = DateTime.add(DateTime.utc_now(), -@lookback_days, :day)
    DateTime.compare(source.inserted_at, cutoff) in [:eq, :gt]
  end

  defp e2ee?(source), do: :e2ee_operator in source.origin_overlays

  defp no_op(reason) do
    summary(nil)
    |> Map.put(:status, "no_op")
    |> Map.put(:stopped_reason, Atom.to_string(reason))
    |> Map.put(:pending_after, nil)
  end

  defp summary(run_id) do
    %{
      status: "completed",
      run_id: run_id,
      scanned: 0,
      created: 0,
      deduplicated: 0,
      abstained: 0,
      secret_dropped: 0,
      protected_dropped: 0,
      protected_routed: 0,
      suppressed: 0,
      failed: 0,
      pending_after: 0,
      stopped_reason: nil,
      hosted_transport_count: 0,
      lookback_days: @lookback_days,
      proposal_cap: @run_proposal_cap,
      pending_cap: @pending_cap
    }
  end

  defp empty_policy_summary do
    summary(nil)
    |> Map.take(
      ~w[created deduplicated abstained secret_dropped protected_dropped protected_routed suppressed failed stopped_reason]a
    )
    |> Map.put(:last_cursor, nil)
  end

  defp merge_summary(acc, policy) do
    [
      :scanned,
      :created,
      :deduplicated,
      :abstained,
      :secret_dropped,
      :protected_dropped,
      :protected_routed,
      :suppressed,
      :failed
    ]
    |> Enum.reduce(acc, fn key, merged ->
      Map.update!(merged, key, &(&1 + Map.get(policy, key, 0)))
    end)
    |> Map.put(:stopped_reason, policy.stopped_reason || acc.stopped_reason)
  end

  defp content_free_summary(result, page) do
    result
    |> Map.drop([:run_id, :last_cursor])
    |> Map.put(:exhausted, page.exhausted?)
    |> Map.put(:hosted_transport_count, 0)
    |> stringify()
  end

  defp control_id(operator_id, policy) do
    digest =
      :crypto.hash(
        :sha256,
        "allbert.memory.consolidation.control.v1\0#{operator_id}\0#{policy.origin_scope}\0#{policy.e2ee?}"
      )
      |> Base.url_encode64(padding: false)

    "memcon:" <> digest
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> fallback
    end
  end

  defp next_cursor(_page, %{stopped_reason: reason, last_cursor: cursor})
       when reason in ["run_proposal_cap", "pending_cap"] and not is_nil(cursor),
       do: cursor

  defp next_cursor(%{exhausted?: true}, _result), do: {nil, nil}
  defp next_cursor(%{cursor: nil}, _result), do: {nil, nil}
  defp next_cursor(page, _result), do: {page.cursor.inserted_at, page.cursor.source_id}

  defp source_cursor(source), do: {source.inserted_at, source.source_id}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value
end
