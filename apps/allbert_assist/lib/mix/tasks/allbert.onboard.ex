defmodule Mix.Tasks.Allbert.Onboard do
  @moduledoc """
  Frame or resume the first-run onboarding objective.

  ## Usage

      mix allbert.onboard [--user USER] [--operator USER]
  """

  use Mix.Task

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
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest)

    user_id = user_id!(opts)

    case Onboarding.frame_or_resume(user_id, %{channel: :cli}) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> fail!(@failure_exit, "Onboarding failed: #{inspect(reason)}")
    end
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

  defp reject_rest!([]), do: :ok

  defp reject_rest!(rest) do
    fail!(@usage_exit, "Unexpected argument(s): #{Enum.join(rest, " ")}")
  end

  defp fail!(code, message), do: throw({:onboarding_error, code, message})

  defp halt(code) do
    halt_fun = Application.get_env(:allbert_assist, __MODULE__, [])[:halt_fun] || (&System.halt/1)
    halt_fun.(code)
  end
end
