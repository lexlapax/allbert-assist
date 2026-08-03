defmodule AllbertAssist.Objectives.Fanout.ReportComposer.Commands.Synthesize do
  @moduledoc false

  use Jido.Action,
    name: "allbert_fanout_report_synthesize",
    description: "Generate one bounded fan-out advisory synthesis."

  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Runs.CancelToken

  @synthesis_contract_version 3

  @impl true
  def run(
        %{
          snapshot: snapshot,
          profile: profile,
          model_context: model_context,
          model_client: model_client,
          deadline_monotonic_ms: deadline_monotonic_ms
        },
        context
      )
      when is_map(snapshot) and is_map(profile) and is_map(model_context) and
             is_atom(model_client) and is_integer(deadline_monotonic_ms) do
    state = Map.get(context, :state, %{})

    result =
      with :ok <- Report.synthesis_eligibility(snapshot),
           {:ok, bounded_input} <- Report.composition_input(snapshot) do
        synthesize(%{
          snapshot: snapshot,
          source_contract: CanonicalJSON.encode(bounded_input),
          profile: profile,
          model_context: model_context,
          model_client: model_client,
          deadline: deadline_monotonic_ms
        })
      end

    {:ok, terminal_state(state, result)}
  end

  def run(_params, context) do
    {:ok,
     terminal_state(
       Map.get(context, :state, %{}),
       {:error, :invalid_synthesis_agent_input}
     )}
  end

  # v1.3 M9.b.6 (ADR 0021 A24): exactly one generation call. No critic round,
  # no revision. Acceptance is deterministic and structural downstream.
  defp synthesize(workflow) do
    with :ok <- active(workflow.model_context),
         {:ok, call_context} <- bounded_context(workflow.model_context, workflow.deadline),
         {:ok, {generated, generation_configuration_sha256}} <-
           invoke_generation(workflow, call_context),
         {:ok, candidate} <- prepare_candidate(workflow.snapshot, generated) do
      accepted(
        Map.put(candidate, :generation_configuration_sha256, generation_configuration_sha256)
      )
    end
  end

  defp invoke_generation(workflow, context) do
    context = ProviderAttempt.put_phase(context, :generation)

    workflow
    |> generation_result(context)
    |> normalize_generation_result()
  end

  defp generation_result(workflow, context) do
    if function_exported?(workflow.model_client, :compose_with_provenance, 3) do
      workflow.model_client.compose_with_provenance(
        workflow.snapshot,
        workflow.profile,
        context
      )
    else
      workflow.model_client.compose(workflow.snapshot, workflow.profile, context)
      |> legacy_generation_result()
    end
  end

  defp legacy_generation_result({:ok, selection}) when is_map(selection),
    do: {:ok, %{candidate: selection, configuration_sha256: nil}}

  defp legacy_generation_result(result), do: result

  defp normalize_generation_result({:ok, %{candidate: selection, configuration_sha256: digest}})
       when is_map(selection) and (is_nil(digest) or is_binary(digest)),
       do: normalize_generation_digest(selection, digest)

  defp normalize_generation_result({:error, {:invalid_model_output, _reason}} = error),
    do: error

  defp normalize_generation_result({:error, {:provider_failed, _reason}} = error), do: error
  defp normalize_generation_result({:error, {:profile_unavailable, _reason}} = error), do: error

  defp normalize_generation_result({:error, reason}),
    do: {:error, {:provider_failed, reason}}

  defp normalize_generation_result(invalid),
    do: {:error, {:provider_failed, {:invalid_generation_result, invalid}}}

  defp normalize_generation_digest(selection, nil), do: {:ok, {selection, nil}}

  defp normalize_generation_digest(selection, digest) do
    if sha256?(digest),
      do: {:ok, {selection, digest}},
      else: {:error, {:provider_failed, :invalid_generation_configuration_digest}}
  end

  defp prepare_candidate(snapshot, selection) do
    with true <- exact_candidate_keys?(selection),
         {:ok, normalized_synthesis} <- normalize_synthesis(selection),
         {:ok, prepared} <-
           Report.prepare_synthesis(snapshot, locally_validated(selection, snapshot)),
         true <- prepared.synthesis_sha256 == sha256(normalized_synthesis) do
      {:ok,
       %{
         prepared: prepared,
         bytes:
           CanonicalJSON.encode(%{
             "sections" => canonical_sections(prepared.layout.sections),
             "advisory_synthesis" => normalized_synthesis
           })
       }}
    else
      {:error, reason} -> {:error, {:invalid_model_output, reason}}
      _invalid -> {:error, {:invalid_model_output, :invalid_synthesis_candidate}}
    end
  end

  defp accepted(candidate) do
    {:ok,
     Map.merge(candidate.prepared, %{
       synthesis_contract_version: @synthesis_contract_version,
       generation_call_count: 1,
       provider_call_count: 1,
       generation_configuration_sha256: Map.get(candidate, :generation_configuration_sha256)
     })}
  end

  # Deterministic local validation, not a review. The composer checks the
  # partition it built against the completed children and records that outcome.
  # It previously also marked every catalog rule "satisfied", which no code
  # evaluated -- the same path that produced the candidate certified it.
  defp locally_validated(selection, snapshot) do
    Map.put(selection, "validation", %{
      "outcome" => "passed",
      "covered_queue_positions" => completed_positions(snapshot)
    })
  end

  defp completed_positions(%{children: children}) do
    children
    |> Enum.filter(&(field(&1, :status) == "completed"))
    |> Enum.map(&field(&1, :queue_position))
    |> Enum.sort()
  end

  defp canonical_sections(sections) do
    Enum.map(sections, fn section ->
      %{
        "relationship" => section.relationship,
        "ordered_queue_positions" => section.ordered_queue_positions
      }
    end)
  end

  defp exact_candidate_keys?(selection) do
    selection
    |> Map.keys()
    |> Enum.map(&normalize_key/1)
    |> Enum.sort()
    |> Kernel.==(~w[advisory_synthesis sections])
  end

  defp normalize_synthesis(selection) do
    case field(selection, :advisory_synthesis) do
      value when is_binary(value) ->
        {:ok,
         value
         |> String.to_charlist()
         |> Enum.map(fn
           codepoint when codepoint < 0x20 or codepoint == 0x7F -> ?\s
           codepoint -> codepoint
         end)
         |> List.to_string()
         |> String.split()
         |> Enum.join(" ")}

      _invalid ->
        {:error, :invalid_fanout_report_synthesis}
    end
  end

  defp bounded_context(context, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case {remaining, Map.get(context, :timeout_ms)} do
      {remaining, configured}
      when remaining > 0 and is_integer(configured) and configured > 0 ->
        {:ok, Map.put(context, :timeout_ms, min(remaining, configured))}

      {remaining, nil} when remaining > 0 ->
        {:ok, Map.put(context, :timeout_ms, remaining)}

      {remaining, _configured} when remaining <= 0 ->
        {:error, :review_deadline_exhausted}

      _invalid ->
        {:error, :invalid_synthesis_timeout_bound}
    end
  end

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, {:phase_review_unresolved, :review_cancelled}}
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(_key), do: :invalid

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower))
  end

  defp sha256?(_value), do: false

  defp terminal_state(state, {:ok, prepared}) do
    Map.merge(state, %{
      status: :accepted,
      prepared: prepared,
      error: nil
    })
  end

  defp terminal_state(state, {:error, reason}) do
    Map.merge(state, %{
      status: :unresolved,
      prepared: nil,
      error: reason
    })
  end
end
