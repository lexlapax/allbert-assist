defmodule Mix.Tasks.Allbert.Onboard do
  @moduledoc """
  Frame or resume the first-run onboarding objective.

  ## Usage

      mix allbert.onboard [--user USER] [--operator USER]
      mix allbert.onboard complete STEP_KEY [--note NOTE]
      mix allbert.onboard skip STEP_KEY [--note NOTE]
      mix allbert.onboard channel telegram|email|none
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Onboarding

  @shortdoc "Frame or resume first-run onboarding"
  @usage_exit 64
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
      {:onboarding_error, code, message} ->
        Mix.shell().error(message)
        halt(code)
    end
  end

  defp dispatch(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string, note: :string])

    reject_invalid!(invalid)

    user_id = user_id!(opts)

    dispatch_rest(rest, user_id, opts)
  end

  defp dispatch_rest([], user_id, _opts) do
    case Onboarding.frame_or_resume(user_id, %{channel: :cli}) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> fail!(@failure_exit, "Onboarding failed: #{inspect(reason)}")
    end
  end

  defp dispatch_rest(["complete", step_key], user_id, opts) do
    record_step(user_id, step_key, "completed", opts[:note] || "CLI onboarding step completed.")
  end

  defp dispatch_rest(["skip", step_key], user_id, opts) do
    record_step(user_id, step_key, "skipped", opts[:note] || "CLI onboarding step skipped.")
  end

  defp dispatch_rest(["channel", "none"], user_id, _opts) do
    record_step(
      user_id,
      "optional_channel_registration",
      "skipped",
      "Operator skipped channel registration."
    )
  end

  defp dispatch_rest(["channel", channel], user_id, _opts)
       when channel in ["telegram", "email"] do
    record_step(
      user_id,
      "optional_channel_registration",
      "completed",
      "Operator selected #{channel} channel registration."
    )
  end

  defp dispatch_rest(rest, _user_id, _opts) do
    fail!(@usage_exit, "Unexpected argument(s): #{Enum.join(rest, " ")}")
  end

  defp print_result({:ok, state}) do
    objective = state.objective

    Mix.shell().info("Onboarding objective: #{objective.id}")
    Mix.shell().info("Status: #{objective.status}")
    Mix.shell().info("Progress: #{objective.progress_summary}")

    if state.current_step do
      Mix.shell().info("Current step: #{state.current_step.index}. #{state.current_step.title}")
    else
      Mix.shell().info("Current step: complete")
    end

    Mix.shell().info("")
    Mix.shell().info("Steps:")

    Enum.each(state.steps, fn step ->
      marker = if state.current_step && step.id == state.current_step.id, do: "*", else: "-"
      optional = if step.optional?, do: " optional", else: ""
      action = if step[:candidate_action], do: " action=#{step.candidate_action}", else: ""

      Mix.shell().info(
        "#{marker} #{step.index}. #{step.title} [#{step.status}]#{optional}#{action}"
      )
    end)
  end

  defp user_id!(opts) do
    user = opts[:user] || "local"
    operator = opts[:operator] || user

    if user == operator do
      user
    else
      fail!(@identity_exit, "Operator must match user for local onboarding.")
    end
  end

  defp reject_invalid!([]), do: :ok

  defp reject_invalid!(invalid) do
    fail!(@usage_exit, "Invalid option(s): #{inspect(invalid)}")
  end

  defp record_step(user_id, step_key, outcome, note) do
    with {:ok, state} <- Onboarding.frame_or_resume(user_id, %{channel: :cli}),
         {:ok, step} <- find_step(state, step_key),
         {:ok, response} <-
           completed_action(
             "onboarding_step_complete",
             %{
               user_id: user_id,
               objective_id: state.objective.id,
               step_id: step.id,
               outcome: outcome,
               note: note
             },
             %{actor: user_id, user_id: user_id, channel: :cli}
           ) do
      {:ok, response_state(response)}
    else
      {:error, reason} -> fail!(@failure_exit, "Onboarding failed: #{inspect(reason)}")
    end
  end

  defp find_step(state, step_key) do
    state.steps
    |> Enum.find(&(to_string(&1.key) == step_key or to_string(&1.index) == step_key))
    |> case do
      nil -> {:error, {:unknown_onboarding_step, step_key}}
      step -> {:ok, step}
    end
  end

  defp completed_action(action_name, params, context) do
    case Runner.run(action_name, params, context) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_state(response) do
    %{
      objective: response.objective,
      steps: response.steps,
      current_step: response.current_step,
      created?: false
    }
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  @spec fail!(non_neg_integer(), String.t()) :: no_return()
  defp fail!(code, message), do: throw({:onboarding_error, code, message})

  defp halt(code) do
    halt_fun = Application.get_env(:allbert_assist, __MODULE__, [])[:halt_fun] || (&System.halt/1)
    halt_fun.(code)
  end
end
