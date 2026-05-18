defmodule Mix.Tasks.Allbert.Delegate do
  @moduledoc """
  Dispatch one registered objective delegate agent from the CLI.

      mix allbert.delegate AGENT_ID '{"ticker":"AAPL"}' [--user USER]
      mix allbert.delegate AGENT_ID --params '{"ticker":"AAPL"}' [--command execute]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry

  @shortdoc "Dispatch a registered objective delegate agent"
  @usage_exit 64
  @not_found_exit 65
  @identity_exit 66
  @failure_exit 1

  @impl true
  def run(args) do
    try do
      Mix.Task.run("app.start")

      args
      |> dispatch()
      |> print_result()
    catch
      {:delegate_error, code, message} ->
        Mix.shell().error(message)
        halt(code)
    end
  end

  defp dispatch([agent_id | rest]) when is_binary(agent_id) do
    {opts, positional, invalid} =
      OptionParser.parse(rest,
        strict: [user: :string, operator: :string, command: :string, params: :string]
      )

    reject_invalid!(invalid)
    user_id = user_id!(opts)
    params = params!(opts, positional)

    with {:ok, entry} <- lookup_agent(agent_id),
         {:ok, objective} <- create_debug_objective(user_id, entry, params),
         {:ok, step} <- create_debug_step(objective, entry, params),
         {:ok, response} <-
           Runner.run(
             "delegate_agent",
             %{
               user_id: user_id,
               objective_id: objective.id,
               step_id: step.id,
               delegate_agent_id: entry.id,
               command: Keyword.get(opts, :command, "execute"),
               params: params
             },
             context(user_id, entry)
           ) do
      finish_debug_objective(objective, step, response)
      {:ok, {:delegate, entry, objective, response}}
    else
      {:error, :not_found} ->
        fail!(@not_found_exit, "Agent #{agent_id} not found in AgentRegistry.")

      {:error, reason} ->
        fail!(@failure_exit, "Delegate command failed: #{inspect(reason)}")
    end
  end

  defp dispatch(_args) do
    fail!(
      @usage_exit,
      """
      Usage:
        mix allbert.delegate AGENT_ID '{"key":"value"}' [--user USER]
        mix allbert.delegate AGENT_ID --params '{"key":"value"}' [--command execute]
      """
    )
  end

  defp print_result({:ok, {:delegate, entry, objective, response}}) do
    Mix.shell().info("Allbert delegate #{entry.id}")
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info("Objective: #{objective.id}")

    state = get_in(response, [:delegate_result, :state]) || %{}

    case Map.get(state, :last_result) || Map.get(state, "last_result") do
      {:ok, report} ->
        Mix.shell().info("Summary: #{summary(report)}")
        Mix.shell().info("Report: #{bounded(report)}")

      {:error, reason} ->
        Mix.shell().info("Error: #{inspect(reason)}")

      _other ->
        Mix.shell().info("Result: #{bounded(response.delegate_result)}")
    end
  end

  defp lookup_agent(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp create_debug_objective(user_id, entry, params) do
    app_id = entry.metadata[:app_id] || entry.metadata["app_id"]

    Objectives.create_objective(%{
      user_id: user_id,
      title: "debug.delegate.#{entry.id}",
      objective: "Delegate #{entry.id} with #{inspect(Map.keys(params))}.",
      active_app: if(is_atom(app_id), do: Atom.to_string(app_id), else: app_id),
      status: "open",
      source_intent: "mix allbert.delegate"
    })
  end

  defp create_debug_step(objective, entry, params) do
    Objectives.create_step(%{
      objective_id: objective.id,
      kind: "delegate_agent",
      status: "selected",
      stage: "execute_step",
      delegate_agent_id: entry.id,
      action_params: params
    })
  end

  defp finish_debug_objective(objective, step, %{status: :completed} = response) do
    {:ok, _step} =
      Objectives.update_step(step, %{
        status: "completed",
        stage: "observe_step",
        result_summary: response.message
      })

    {:ok, _objective} =
      Objectives.update_objective(objective, %{
        status: "completed",
        progress_summary: response.message,
        completed_at: DateTime.utc_now()
      })

    :ok
  end

  defp finish_debug_objective(objective, step, response) do
    {:ok, _step} =
      Objectives.update_step(step, %{status: "failed", result_summary: inspect(response)})

    {:ok, _objective} =
      Objectives.update_objective(objective, %{
        status: "failed",
        progress_summary: inspect(response)
      })

    :ok
  end

  defp params!(opts, positional) do
    params_source =
      Keyword.get(opts, :params) ||
        case positional do
          [] -> "{}"
          [json] -> json
          rest -> fail!(@usage_exit, "Unexpected delegate arguments: #{inspect(rest)}")
        end

    case Jason.decode(params_source) do
      {:ok, %{} = params} -> params
      {:ok, _other} -> fail!(@usage_exit, "Delegate params must decode to a JSON object.")
      {:error, reason} -> fail!(@usage_exit, "Invalid delegate params JSON: #{inspect(reason)}")
    end
  end

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        fail!(@identity_exit, "--user and --operator must match when both are provided.")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp context(user_id, entry) do
    app_id = entry.metadata[:app_id] || entry.metadata["app_id"]

    %{
      request: %{channel: :cli, user_id: user_id, operator_id: user_id, app_id: app_id},
      channel: :cli,
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: "cli",
      app_id: app_id
    }
  end

  defp summary(%{} = report) do
    Map.get(report, :summary) || Map.get(report, "summary") ||
      inspect(Map.take(report, [:status]))
  end

  defp summary(report), do: inspect(report)

  defp bounded(value) do
    text = inspect(value, limit: 20, printable_limit: 1_200)
    if byte_size(text) > 1_200, do: binary_part(text, 0, 1_200), else: text
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Unknown options: #{inspect(invalid)}")

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  @spec fail!(non_neg_integer(), String.t()) :: no_return()
  defp fail!(code, message), do: throw({:delegate_error, code, message})

  defp halt(code) do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:halt_fun, &System.halt/1)
    |> then(& &1.(code))
  end
end
