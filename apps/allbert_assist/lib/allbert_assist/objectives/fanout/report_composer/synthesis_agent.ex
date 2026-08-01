defmodule AllbertAssist.Objectives.Fanout.ReportComposer.SynthesisAgent do
  @moduledoc """
  Ephemeral Jido lifecycle for one claimed fan-out report synthesis.

  Jido.Agent fits this bounded `deterministic_baseline -> accepted | unresolved`
  state transition and keeps the private synthesis command composable. It owns
  no durable queue or authority: `ReportComposer` remains the plain GenServer
  owner of claim serialization, retry, compare-and-set persistence, and
  recovery, and this agent is discarded before that durable owner selects a
  report.
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

  alias AllbertAssist.Objectives.Fanout.ReportComposer.Commands.Synthesize

  @spec run(map(), map(), map(), module(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def run(snapshot, profile, model_context, model_client, timeout_ms)
      when is_map(snapshot) and is_map(profile) and is_map(model_context) and
             is_atom(model_client) and is_integer(timeout_ms) and timeout_ms > 0 do
    lifecycle =
      Task.async(fn -> execute(snapshot, profile, model_context, model_client) end)

    await(lifecycle, timeout_ms)
  end

  def run(_snapshot, _profile, _model_context, _model_client, _timeout_ms),
    do: {:error, :invalid_synthesis_agent_input}

  defp execute(snapshot, profile, model_context, model_client) do
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
      model_client: model_client
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

  defp await(lifecycle, timeout_ms) do
    case Task.yield(lifecycle, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        exit({:fanout_synthesis_lifecycle_exit, reason})

      nil ->
        _ = Task.shutdown(lifecycle, :brutal_kill)
        {:error, :fanout_synthesis_timeout}
    end
  end
end
