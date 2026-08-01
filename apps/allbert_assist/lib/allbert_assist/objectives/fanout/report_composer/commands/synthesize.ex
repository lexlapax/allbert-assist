defmodule AllbertAssist.Objectives.Fanout.ReportComposer.Commands.Synthesize do
  @moduledoc false

  use Jido.Action,
    name: "allbert_fanout_report_synthesize",
    description: "Run and locally validate one bounded fan-out advisory synthesis."

  alias AllbertAssist.Objectives.Fanout.Report

  @impl true
  def run(
        %{
          snapshot: snapshot,
          profile: profile,
          model_context: model_context,
          model_client: model_client
        },
        context
      )
      when is_map(snapshot) and is_map(profile) and is_map(model_context) and
             is_atom(model_client) do
    state = Map.get(context, :state, %{})

    result =
      with :ok <- Report.synthesis_eligibility(snapshot),
           {:ok, _bounded_input} <- Report.composition_input(snapshot) do
        compose_and_validate(snapshot, profile, model_context, model_client)
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

  defp compose_and_validate(snapshot, profile, model_context, model_client) do
    case model_client.compose(snapshot, profile, model_context) do
      {:ok, selection} ->
        case Report.prepare_synthesis(snapshot, selection) do
          {:ok, prepared} -> {:ok, prepared}
          {:error, reason} -> {:error, {:invalid_model_output, reason}}
        end

      {:error, {:invalid_model_output, _reason}} = error ->
        error

      {:error, {:provider_failed, _reason}} = error ->
        error

      {:error, {:profile_unavailable, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:provider_failed, reason}}
    end
  end

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
