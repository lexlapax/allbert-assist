defmodule Mix.Tasks.Allbert.Plan do
  @moduledoc """
  Inspect and cancel v0.44 Plan/Build runs.

  ## Usage

      mix allbert.plan list [--format ids] [--status running] [--user USER]
      mix allbert.plan show OBJECTIVE_ID [--user USER]
      mix allbert.plan cancel OBJECTIVE_ID --reason REASON [--user USER]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Inspect and cancel Plan/Build runs"
  @usage_exit 64
  @not_found_exit 65
  @failure_exit 1
  @dialyzer {:nowarn_function, fail!: 2}

  @impl true
  def run(args) do
    try do
      Mix.Task.run("app.start")

      args
      |> dispatch()
      |> print_result()
    catch
      {:plan_error, code, message} ->
        Mix.shell().error(message)
        System.halt(code)
    end
  end

  defp dispatch(["list" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [format: :string, status: :string, user: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "list")

    params =
      %{
        user_id: user_id(opts),
        status: opts[:status],
        format: opts[:format]
      }
      |> drop_nil()

    with {:ok, %{status: :completed, output_data: output_data}} <-
           Runner.run("list_plan_runs", params, context(params[:user_id])) do
      {:ok, {:list, output_data, opts[:format]}}
    else
      {:ok, response} -> {:error, response}
    end
  end

  defp dispatch(["show", objective_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string])
    reject_invalid!(invalid)
    reject_rest!(rest, "show")

    params = %{id: objective_id, user_id: user_id(opts)}

    with {:ok, %{status: :completed} = response} <-
           Runner.run("show_objective", params, context(params.user_id)) do
      {:ok, {:show, response}}
    else
      {:ok, %{status: :not_found}} -> fail!(@not_found_exit, "Plan run not found.")
      {:ok, response} -> {:error, response}
    end
  end

  defp dispatch(["cancel", objective_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [reason: :string, user: :string])
    reject_invalid!(invalid)
    reject_rest!(rest, "cancel")

    params = %{
      objective_id: objective_id,
      user_id: user_id(opts),
      reason: required_reason!(opts)
    }

    with {:ok, %{status: :cancelled} = response} <-
           Runner.run("cancel_plan_run", params, context(params.user_id)) do
      {:ok, {:cancel, response}}
    else
      {:ok, response} -> {:error, response}
    end
  end

  defp dispatch(_args) do
    fail!(
      @usage_exit,
      """
      Usage:
        mix allbert.plan list [--format ids] [--status running] [--user USER]
        mix allbert.plan show OBJECTIVE_ID [--user USER]
        mix allbert.plan cancel OBJECTIVE_ID --reason REASON [--user USER]
      """
    )
  end

  defp print_result({:ok, {:list, %{ids: ids}, "ids"}}) do
    Enum.each(ids, fn id -> Mix.shell().info(id) end)
  end

  defp print_result({:ok, {:list, %{plans: []}, _format}}), do: Mix.shell().info("No plan runs.")

  defp print_result({:ok, {:list, %{plans: plans}, _format}}) do
    Enum.each(plans, fn plan ->
      Mix.shell().info("#{plan.id} #{plan.status} #{plan.source_intent || "workflow:none"}")
    end)
  end

  defp print_result({:ok, {:show, response}}) do
    objective = response.objective
    Mix.shell().info("Plan: #{objective.id}")
    Mix.shell().info("Status: #{objective.status}")
    Mix.shell().info("Workflow: #{objective[:source_intent] || "none"}")
    Mix.shell().info("Steps: #{length(response.steps)}")
    Mix.shell().info("Events: #{length(response.events)}")
  end

  defp print_result({:ok, {:cancel, response}}) do
    Mix.shell().info(response.message)
  end

  defp print_result({:error, reason}) do
    fail!(@failure_exit, "Plan command failed: #{inspect(reason)}")
  end

  defp context(nil), do: context("local")

  defp context(user_id) do
    ContextBuilder.cli_context(actor: "local", user_id: user_id, surface: "mix allbert.plan")
  end

  defp user_id(opts), do: Keyword.get(opts, :user, "local")

  defp required_reason!(opts) do
    case Keyword.get(opts, :reason) do
      value when is_binary(value) and value != "" -> value
      _other -> fail!(@usage_exit, "--reason is required")
    end
  end

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Invalid options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: fail!(@usage_exit, "Unexpected #{command} args: #{inspect(rest)}")

  defp fail!(code, message), do: throw({:plan_error, code, message})
end
