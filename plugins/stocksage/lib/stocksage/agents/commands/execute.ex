defmodule StockSage.Agents.Commands.Execute do
  @moduledoc "M2 stub execution command for StockSage native specialist agents."

  use Jido.Action,
    name: "stocksage_native_agent_execute",
    description: "Return a bounded stub report packet for a StockSage native agent."

  alias AllbertAssist.Actions.Runner
  alias StockSage.Agents
  alias StockSage.Agents.ModelProfile

  @impl true
  def run(params, context) do
    agent_id =
      context
      |> Map.get(:state, %{})
      |> field(:agent_id)
      |> case do
        nil -> field(params, :agent_id)
        value -> value
      end

    report = report_for(agent_id, params, context)

    {:ok,
     %{
       last_command: :execute,
       last_result: {:ok, report},
       last_summary: report.summary,
       agent_id: report.agent_id,
       role: report.role,
       prompt_version: report.prompt_version,
       model_profile: report.model_profile
     }}
  end

  @spec report_for(String.t(), map()) :: map()
  def report_for(agent_id, request) when is_binary(agent_id) and is_map(request) do
    report_for(agent_id, request, %{})
  end

  @spec report_for(String.t(), map(), map()) :: map()
  def report_for(agent_id, request, context) when is_binary(agent_id) and is_map(request) do
    spec = Agents.spec!(agent_id)
    model_profile = if spec.role == :quality_gate, do: nil, else: ModelProfile.resolve(spec.role)
    now = DateTime.utc_now()
    evidence = evidence_for(spec, request, context)

    %{
      agent_id: spec.id,
      role: spec.role,
      request_id: field(request, :request_id) || "stub-#{System.unique_integer([:positive])}",
      status: :ok,
      summary: "Stub #{spec.role} report for #{field(request, :ticker, "UNKNOWN")}.",
      report: "",
      evidence_used: evidence,
      confidence: 0.5,
      warnings: ["v0.25 M2 skeleton stub; no LLM call executed"],
      data_requests: [],
      generated_at: now,
      duration_ms: 0,
      model_profile: model_profile,
      prompt_version: spec.prompt_version
    }
  end

  defp evidence_for(%{tool_modules: modules}, request, context) when is_list(modules) do
    Enum.map(modules, fn module ->
      case Runner.run(module.name(), evidence_params(request), evidence_context(request, context)) do
        {:ok, response} ->
          %{
            action: module.name(),
            status: Map.get(response, :status),
            evidence: Map.get(response, :evidence),
            message: Map.get(response, :message)
          }
          |> drop_nil()
          |> bound_evidence()
      end
    end)
  end

  defp evidence_for(_spec, _request, _context), do: []

  defp evidence_params(request) do
    %{
      ticker: field(request, :ticker, "UNKNOWN"),
      analysis_date: field(request, :analysis_date, "2026-05-15"),
      evidence_mode: field(request, :evidence_mode),
      fixture: field(request, :fixture, false),
      user_id: field(request, :user_id)
    }
    |> drop_nil()
  end

  defp evidence_context(request, context) do
    user_id = field(request, :user_id) || get_in_field(context, [:request, :user_id]) || "local"

    %{
      request: %{
        channel: :objective_agent,
        user_id: user_id,
        operator_id: field(request, :operator_id) || user_id,
        app_id: :stocksage
      },
      parent: field(context, :parent, %{})
    }
  end

  defp get_in_field(value, keys) do
    Enum.reduce_while(keys, value, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp bound_evidence(%{evidence: evidence} = summary) when is_map(evidence) do
    Map.put(
      summary,
      :evidence,
      Map.take(evidence, [:kind, :mode, :ticker, :analysis_date, :source])
    )
  end

  defp bound_evidence(summary), do: summary

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
