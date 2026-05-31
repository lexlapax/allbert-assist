defmodule Mix.Tasks.Allbert.Browser do
  @moduledoc """
  Browser/web-research operator helpers.
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Run browser doctor and simple browser helper commands"

  @impl true
  def run(["doctor" | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("browser_doctor", %{}, %{actor: "local", channel: :cli}) do
      {:ok, %{status: :completed, doctor: doctor}} ->
        Mix.shell().info("browser doctor: #{doctor.live_check_status}")
        Mix.shell().info(Jason.encode!(doctor))

      {:ok, response} ->
        Mix.shell().error("browser doctor failed: #{inspect(response.error || response.status)}")
    end
  end

  def run(_args) do
    Mix.shell().info("Usage: mix allbert.browser doctor")
  end
end
