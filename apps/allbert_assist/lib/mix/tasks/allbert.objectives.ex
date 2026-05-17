defmodule Mix.Tasks.Allbert.Objectives do
  @moduledoc """
  Inspect durable Allbert objectives.

  ## Usage

      mix allbert.objectives list [--user USER] [--status open] [--active-app stocksage] [--limit 20]
      mix allbert.objectives show OBJECTIVE_ID [--user USER]
      mix allbert.objectives continue OBJECTIVE_ID [--user USER]
      mix allbert.objectives cancel OBJECTIVE_ID --reason REASON [--user USER]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect durable Allbert objectives"
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
      {:objectives_error, code, message} ->
        Mix.shell().error(message)
        halt(code)
    end
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

  defp dispatch(["continue", id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "continue")
    user_id = user_id!(opts)

    case Runner.run("continue_objective", %{id: id, user_id: user_id}, context(user_id)) do
      {:ok, %{status: status} = response}
      when status in [
             :completed,
             :needs_confirmation,
             :still_blocked,
             :objective_abandoned,
             :objective_cancelled,
             :objective_failed
           ] ->
        {:ok, {:continue, response}}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp dispatch(["cancel", id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          user: :string,
          operator: :string,
          reason: :string
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "cancel")
    user_id = user_id!(opts)
    reason = required_reason!(opts)

    case Runner.run(
           "cancel_objective",
           %{id: id, user_id: user_id, reason: reason},
           context(user_id)
         ) do
      {:ok, %{status: :cancelled} = response} ->
        {:ok, {:cancel, response}}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp dispatch(_args) do
    fail!(
      @usage_exit,
      """
      Usage:
        mix allbert.objectives list [--user USER] [--status open|running|blocked|completed|cancelled|failed|abandoned] [--active-app APP_ID] [--limit N]
        mix allbert.objectives show OBJECTIVE_ID [--user USER]
        mix allbert.objectives continue OBJECTIVE_ID [--user USER]
        mix allbert.objectives cancel OBJECTIVE_ID --reason REASON [--user USER]
      """
    )
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
    fail!(@not_found_exit, "Objective not found.")
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

  defp print_result({:ok, {:continue, response}}) do
    Mix.shell().info(response.message)

    if Map.get(response, :confirmation_id) do
      Mix.shell().info("Confirmation: #{response.confirmation_id}")
    end

    if Map.get(response, :reason) do
      Mix.shell().info("Reason: #{response.reason}")
    end
  end

  defp print_result({:ok, {:cancel, response}}) do
    Mix.shell().info(response.message)

    if Map.get(response, :cancelled_step_count) do
      Mix.shell().info("Cancelled steps: #{response.cancelled_step_count}")
    end
  end

  defp print_result({:error, reason}) do
    fail!(error_code(reason), "Objectives command failed: #{inspect(reason)}")
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
        fail!(@identity_exit, "--user and --operator must match when both are provided.")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp required_reason!(opts) do
    opts[:reason]
    |> blank_to_nil()
    |> case do
      nil -> fail!(@usage_exit, "Usage error (64): cancel requires --reason REASON.")
      reason -> reason
    end
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Unknown options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: fail!(@usage_exit, "Unexpected #{command} arguments: #{inspect(rest)}")

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

  defp error_code(:not_found), do: @not_found_exit
  defp error_code({:not_found, _id}), do: @not_found_exit
  defp error_code(:missing_reason), do: @usage_exit
  defp error_code(:missing_objective_id), do: @usage_exit
  defp error_code(:missing_user_id), do: @usage_exit
  defp error_code(_reason), do: @failure_exit

  @spec fail!(non_neg_integer(), String.t()) :: no_return()
  defp fail!(code, message), do: throw({:objectives_error, code, message})

  defp halt(code) do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:halt_fun, &System.halt/1)
    |> then(& &1.(code))
  end
end
