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

  def run(["sessions", "list" | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("browser_list_sessions", %{}, %{actor: "local", channel: :cli}) do
      {:ok, %{status: :completed, sessions: sessions}} ->
        Enum.each(sessions, fn session ->
          Mix.shell().info(
            Enum.join(
              [
                session.session_id,
                "age_ms=#{session.age_ms}",
                "last_visited_host=#{session.last_visited_host || "-"}"
              ],
              " "
            )
          )
        end)

      {:ok, response} ->
        Mix.shell().error("browser sessions list failed: #{inspect(response.error || response.status)}")
    end
  end

  def run(["sessions", "close", session_id | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("browser_close_session", %{session_id: session_id}, %{actor: "local", channel: :cli}) do
      {:ok, %{status: :completed}} ->
        Mix.shell().info("browser session closed: #{session_id}")

      {:ok, response} ->
        Mix.shell().error("browser session close failed: #{inspect(response.error || response.status)}")
    end
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix allbert.browser doctor
      mix allbert.browser sessions list
      mix allbert.browser sessions close <session_id>
    """)
  end
end
