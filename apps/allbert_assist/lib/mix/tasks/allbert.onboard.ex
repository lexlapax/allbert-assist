defmodule Mix.Tasks.Allbert.Onboard do
  @moduledoc """
  Drive the guided onboarding wizard from Mix — the dev/CI mirror of the packaged
  `allbert onboard` verb.

  v0.63 M7.3: re-pointed off the retired objective flow onto the shared wizard state
  machine (`AllbertAssist.CLI.Areas.Onboarding`). All arguments/flags pass straight
  through to that dispatcher.

  ## Usage

      mix allbert.onboard                    # resume (or show) the wizard
      mix allbert.onboard --quickstart       # start the QuickStart track
      mix allbert.onboard --advanced         # start the Advanced track
      mix allbert.onboard status             # compact wizard status
      mix allbert.onboard advance STEP       # record the current step done
      mix allbert.onboard apply-persona ID --authorize --yes
      mix allbert.onboard --reset --yes      # reset onboarding (marker only)
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas.Onboarding, as: OnboardArea
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Guided onboarding wizard (mirrors `allbert onboard`)"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    context =
      ContextBuilder.cli_context(%{
        actor: "local",
        operator_id: "local",
        surface: "mix allbert.onboard"
      })

    {output, code} = OnboardArea.dispatch(args, context)

    output |> String.trim_trailing() |> Mix.shell().info()

    if code != 0 do
      halt(code)
    else
      :ok
    end
  end

  defp halt(code) do
    halt_fun = Application.get_env(:allbert_assist, __MODULE__, [])[:halt_fun] || (&System.halt/1)
    halt_fun.(code)
  end
end
