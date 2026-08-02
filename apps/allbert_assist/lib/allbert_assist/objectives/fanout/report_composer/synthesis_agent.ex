defmodule AllbertAssist.Objectives.Fanout.ReportComposer.SynthesisAgent do
  @moduledoc """
  Ephemeral Jido lifecycle for one claimed fan-out report synthesis.

  Jido.Agent fits this bounded `generate -> critique -> optional revision ->
  fresh verification -> accepted | unresolved` state transition and keeps the
  private synthesis command composable. It owns no durable queue or authority:
  `ReportComposer` remains the plain GenServer owner of claim serialization,
  retry, compare-and-set persistence, and recovery, and this agent is discarded
  before that durable owner selects a report.
  """

  @dialyzer {:nowarn_function, __agent_metadata__: 0}
  @dialyzer {:nowarn_function, actions: 0}
  @dialyzer {:nowarn_function, signal_routes: 0}
  @dialyzer {:nowarn_function, validate: 2}

  use Jido.Agent,
    name: "allbert_fanout_report_synthesis",
    description: "Validate one bounded advisory synthesis for a claimed fan-out report.",
    signal_routes: [
      {"allbert.objectives.fanout.synthesize",
       AllbertAssist.Objectives.Fanout.ReportComposer.Commands.Synthesize}
    ]

  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.Fanout.ReportComposer.Commands.Synthesize

  @spec run(map(), map(), map(), module(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def run(snapshot, profile, model_context, model_client, timeout_ms)
      when is_map(snapshot) and is_map(profile) and is_map(model_context) and
             is_atom(model_client) and is_integer(timeout_ms) and timeout_ms > 0 do
    monotonic_now = monotonic_now(model_context)
    deadline_monotonic_ms = monotonic_now.() + timeout_ms
    # Reuse a caller-supplied counter so attempt evidence outlives this call.
    # A failure returns a bare error tuple, so an owner that needs to record
    # what the failed row actually consumed cannot recover it afterwards from
    # a counter this function created and dropped.
    {model_context, provider_attempt_counter} = ProviderAttempt.attach_or_reuse(model_context)

    model_context =
      Map.put_new(
        model_context,
        :fanout_deadline_unix_ms,
        System.system_time(:millisecond) + timeout_ms
      )

    lifecycle =
      Task.async(fn ->
        execute(
          snapshot,
          profile,
          model_context,
          model_client,
          deadline_monotonic_ms
        )
      end)

    lifecycle
    |> await(deadline_monotonic_ms, monotonic_now)
    |> bind_provider_attempt_count(provider_attempt_counter)
  end

  def run(_snapshot, _profile, _model_context, _model_client, _timeout_ms),
    do: {:error, :invalid_synthesis_agent_input}

  defp execute(snapshot, profile, model_context, model_client, deadline_monotonic_ms) do
    agent =
      new(
        id: "fanout-report-synthesis-#{System.unique_integer([:positive, :monotonic])}",
        state: %{
          status: :deterministic_baseline,
          prepared: nil,
          error: nil
        }
      )

    payload = %{
      snapshot: snapshot,
      profile: profile,
      model_context: model_context,
      model_client: model_client,
      deadline_monotonic_ms: deadline_monotonic_ms
    }

    {agent, _directives} =
      cmd(agent, {Synthesize, payload},
        timeout: 0,
        max_retries: 0,
        __jido_instance__: AllbertAssist.Jido
      )

    case agent.state do
      %{status: :accepted, prepared: prepared} when is_map(prepared) -> {:ok, prepared}
      %{status: :unresolved, error: reason} -> {:error, reason}
      _invalid -> {:error, :invalid_synthesis_agent_result}
    end
  end

  defp await(lifecycle, deadline_monotonic_ms, monotonic_now) do
    remaining = deadline_monotonic_ms - monotonic_now.()

    if remaining > 0 do
      lifecycle
      |> Task.yield(remaining)
      |> resolve_await(lifecycle, deadline_monotonic_ms, monotonic_now)
    else
      timeout(lifecycle)
    end
  end

  defp resolve_await({:ok, result}, _lifecycle, deadline, monotonic_now) do
    if monotonic_now.() < deadline,
      do: result,
      else: {:error, :fanout_synthesis_timeout}
  end

  defp resolve_await({:exit, reason}, _lifecycle, _deadline, _monotonic_now),
    do: exit({:fanout_synthesis_lifecycle_exit, reason})

  defp resolve_await(nil, lifecycle, _deadline, _monotonic_now), do: timeout(lifecycle)

  defp timeout(lifecycle) do
    _ = Task.shutdown(lifecycle, :brutal_kill)
    {:error, :fanout_synthesis_timeout}
  end

  # v1.3 M9.b.6 (ADR 0021 A24): one generation, no revision phase.
  defp bind_provider_attempt_count(
         {:ok, %{generation_call_count: 1}} = result,
         provider_attempt_counter
       ) do
    expect_provider_attempts(
      provider_attempt_counter,
      %{total: 1, generation: 1, revision: 0},
      result
    )
  end

  defp bind_provider_attempt_count({:error, _reason} = error, provider_attempt_counter) do
    observed = ProviderAttempt.phase_counts(provider_attempt_counter)

    if valid_failure_attempt_sequence?(observed),
      do: error,
      else: provider_attempt_mismatch(:ordered_single_attempt_per_phase, observed)
  end

  defp bind_provider_attempt_count(_invalid, provider_attempt_counter) do
    provider_attempt_mismatch(
      %{total: 1, generation: 1, revision: 0},
      ProviderAttempt.phase_counts(provider_attempt_counter)
    )
  end

  defp expect_provider_attempts(provider_attempt_counter, expected, result) do
    observed = ProviderAttempt.phase_counts(provider_attempt_counter)

    if observed == expected,
      do: result,
      else: provider_attempt_mismatch(expected, observed)
  end

  defp valid_failure_attempt_sequence?(%{total: 0, generation: 0, revision: 0}), do: true
  defp valid_failure_attempt_sequence?(%{total: 1, generation: 1, revision: 0}), do: true
  defp valid_failure_attempt_sequence?(%{total: 2, generation: 1, revision: 1}), do: true
  defp valid_failure_attempt_sequence?(_counts), do: false

  defp provider_attempt_mismatch(expected, observed) do
    {:error,
     {:fanout_synthesis_provider_attempt_mismatch, %{expected: expected, observed: observed}}}
  end

  defp monotonic_now(model_context) do
    case Map.get(model_context, :synthesis_monotonic_now) do
      monotonic_now when is_function(monotonic_now, 0) -> monotonic_now
      _default -> fn -> System.monotonic_time(:millisecond) end
    end
  end
end
