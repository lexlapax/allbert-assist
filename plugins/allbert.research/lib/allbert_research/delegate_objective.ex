defmodule AllbertResearch.DelegateObjective do
  @moduledoc """
  Shared objective + `delegate_agent` step machinery for `research.specialist`.

  Both `mix allbert.research` and the `browser_research_handoff` action route
  through this module (v1.0.1 M4.2), so the chat-turn path and the CLI path
  run the same supervised delegate: one objective, one `delegate_agent` step,
  executed through the objective engine. No authority is added here — browser
  sessions, navigation grants, and confirmations are enforced downstream by
  the delegate's `AllbertAssist.Actions.Runner.run/3` calls.
  """

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent

  @doc """
  Create and execute one bounded research delegate objective.

  Options:

    * `:session_id` — reuse an already-started browser session (CLI path);
      omitted, the delegate starts its own session behind the existing
      confirmation machinery.
    * `:max_sources` — bound the source count.
    * `:channel` — origin channel recorded on browser actions (default `:cli`).
    * `:extract_format` — extraction format forwarded to the delegate.
    * `:source_intent` — objective provenance (default `"mix allbert.research"`).
    * `:trace_prefix` — trace id prefix (default `"cli_research"`).

  Returns `{:ok, run}` with `:command`, `:objective`, `:step`, `:result`,
  `:status`, and `:confirmation_id`, or `{:error, reason}`.
  """
  @spec start(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(user_id, target, opts \\ []) do
    command = command_for_target(target)
    trace_prefix = Keyword.get(opts, :trace_prefix, "cli_research")

    with {:ok, objective} <- create_objective(user_id, target, opts),
         {:ok, step} <- create_step(objective, command, target, user_id, opts),
         {:ok, execute_result} <-
           EngineAgent.execute_step(%{
             step_id: step.id,
             trace_id: "#{trace_prefix}_#{System.unique_integer([:positive])}"
           }),
         {:ok, objective} <- maybe_observe_completed(objective, execute_result, trace_prefix) do
      {:ok,
       %{
         command: command,
         objective: objective,
         step: Map.get(execute_result, :step),
         result: Map.get(execute_result, :result),
         status: Map.get(execute_result, :status),
         confirmation_id: Map.get(execute_result, :confirmation_id)
       }}
    end
  end

  @doc "Return the delegate command for a research target."
  @spec command_for_target(String.t()) :: :summarize_url | :research
  def command_for_target(target) do
    if url_target?(target), do: :summarize_url, else: :research
  end

  @doc "Return whether the target parses as an http(s) URL."
  @spec url_target?(String.t()) :: boolean()
  def url_target?(target) do
    case URI.parse(String.trim(target)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp create_objective(user_id, target, opts) do
    Objectives.create_objective(%{
      user_id: user_id,
      title: "research.specialist",
      objective: "Research #{target}.",
      active_app: "allbert_research",
      status: "open",
      source_intent: Keyword.get(opts, :source_intent, "mix allbert.research")
    })
  end

  defp create_step(objective, command, target, user_id, opts) do
    Objectives.create_step(%{
      objective_id: objective.id,
      kind: "delegate_agent",
      status: "selected",
      stage: "execute_step",
      delegate_agent_id: AllbertResearch.Runtime.agent_id(),
      action_params: %{
        command: Atom.to_string(command),
        params: params_for(command, target, user_id, opts)
      }
    })
  end

  defp params_for(command, target, user_id, opts) do
    target_key = if command == :summarize_url, do: :url, else: :topic

    %{
      user_id: user_id,
      channel: Keyword.get(opts, :channel, :cli)
    }
    |> Map.put(target_key, target)
    |> maybe_put(:session_id, Keyword.get(opts, :session_id))
    |> maybe_put(:max_sources, Keyword.get(opts, :max_sources))
    |> maybe_put(:extract_format, Keyword.get(opts, :extract_format))
  end

  defp maybe_observe_completed(objective, %{status: :completed, step: step}, trace_prefix)
       when not is_nil(step) do
    case EngineAgent.observe_step(%{
           step_id: step.id,
           trace_id: "#{trace_prefix}_observe_#{System.unique_integer([:positive])}"
         }) do
      {:ok, %{objective: objective}} -> {:ok, objective}
      {:error, _reason} -> Objectives.get_objective(objective.id)
    end
  end

  defp maybe_observe_completed(objective, _execute_result, _trace_prefix),
    do: Objectives.get_objective(objective.id)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
