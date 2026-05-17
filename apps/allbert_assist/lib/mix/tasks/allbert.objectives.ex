defmodule Mix.Tasks.Allbert.Objectives do
  @moduledoc """
  Inspect durable Allbert objectives.

  ## Usage

      mix allbert.objectives list [--user USER] [--status open] [--active-app stocksage] [--limit 20]
      mix allbert.objectives show OBJECTIVE_ID [--user USER]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect durable Allbert objectives"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          user: :string,
          operator: :string,
          status: :string,
          active_app: :string,
          limit: :integer
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "list")
    user_id = user_id!(opts)

    params =
      %{
        user_id: user_id,
        status: opts[:status],
        active_app: opts[:active_app],
        limit: opts[:limit]
      }
      |> drop_nil()

    with {:ok, response} <- completed_action("list_objectives", params, user_id) do
      {:ok, {:list, response.objectives}}
    end
  end

  defp dispatch(["show", id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "show")
    user_id = user_id!(opts)

    with {:ok, response} <-
           accepted_action("show_objective", %{id: id, user_id: user_id}, user_id) do
      {:ok, {:show, response}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.objectives list [--user USER] [--status open|running|blocked|completed|cancelled|failed|abandoned] [--active-app APP_ID] [--limit N]
      mix allbert.objectives show OBJECTIVE_ID [--user USER]
    """)
  end

  defp print_result({:ok, {:list, []}}) do
    Mix.shell().info("No objectives.")
  end

  defp print_result({:ok, {:list, objectives}}) do
    Enum.each(objectives, fn objective ->
      Mix.shell().info(
        "#{objective.id} #{objective.status} app=#{objective.active_app || "none"} #{objective.title}"
      )
    end)
  end

  defp print_result({:ok, {:show, %{status: :not_found}}}) do
    Mix.raise("Objective not found.")
  end

  defp print_result({:ok, {:show, response}}) do
    objective = response.objective

    Mix.shell().info("Objective: #{objective.id}")
    Mix.shell().info("Title: #{objective.title}")
    Mix.shell().info("Status: #{objective.status}")
    Mix.shell().info("User: #{objective.user_id}")
    print_field("Active app", objective[:active_app])
    print_field("Thread", objective[:source_thread_id])
    Mix.shell().info("")
    Mix.shell().info(objective.objective)

    Mix.shell().info("")
    Mix.shell().info("Steps:")
    print_steps(response.steps)

    Mix.shell().info("")
    Mix.shell().info("Events:")
    print_events(response.events)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Objectives command failed: #{inspect(reason)}")
  end

  defp print_steps([]), do: Mix.shell().info("- none")

  defp print_steps(steps) do
    Enum.each(steps, fn step ->
      Mix.shell().info(
        "- #{step.id} #{step.status} #{step.kind} stage=#{step.stage} action=#{step[:candidate_action] || "none"}"
      )
    end)
  end

  defp print_events([]), do: Mix.shell().info("- none")

  defp print_events(events) do
    Enum.each(events, fn event ->
      Mix.shell().info("- #{event.kind} #{event.summary || ""}")
    end)
  end

  defp print_field(_label, nil), do: :ok
  defp print_field(label, value), do: Mix.shell().info("#{label}: #{value}")

  defp completed_action(action_name, params, user_id) do
    case Runner.run(action_name, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp accepted_action(action_name, params, user_id) do
    case Runner.run(action_name, params, context(user_id)) do
      {:ok, %{status: status} = response} when status in [:completed, :not_found] ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message
  defp response_error(response), do: response

  defp context(user_id),
    do: %{actor: user_id, user_id: user_id, operator_id: user_id, channel: :cli}

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        Mix.raise("--user and --operator must match when both are provided.")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Unknown options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: Mix.raise("Unexpected #{command} arguments: #{inspect(rest)}")

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

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
