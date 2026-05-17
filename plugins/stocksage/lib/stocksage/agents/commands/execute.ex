defmodule StockSage.Agents.Commands.Execute do
  @moduledoc "M2 stub execution command for StockSage native specialist agents."

  use Jido.Action,
    name: "stocksage_native_agent_execute",
    description: "Return a bounded stub report packet for a StockSage native agent."

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

    report = report_for(agent_id, params)

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
    spec = Agents.spec!(agent_id)
    model_profile = if spec.role == :quality_gate, do: nil, else: ModelProfile.resolve(spec.role)
    now = DateTime.utc_now()

    %{
      agent_id: spec.id,
      role: spec.role,
      request_id: field(request, :request_id) || "stub-#{System.unique_integer([:positive])}",
      status: :ok,
      summary: "Stub #{spec.role} report for #{field(request, :ticker, "UNKNOWN")}.",
      report: "",
      evidence_used: [],
      confidence: 0.5,
      warnings: ["v0.25 M2 skeleton stub; no LLM call executed"],
      data_requests: [],
      generated_at: now,
      duration_ms: 0,
      model_profile: model_profile,
      prompt_version: spec.prompt_version
    }
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
