defmodule Mix.Tasks.Allbert.Browser do
  @moduledoc """
  Browser/web-research operator helpers.
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Pack.EffectGuard

  @shortdoc "Run browser doctor and simple browser helper commands"

  @impl true
  def run(["doctor" | _rest]) do
    Mix.Task.run("app.start")

    with_ready_context(fn context ->
      case Runner.run("browser_doctor", %{}, context) do
        {:ok, %{status: :completed, doctor: doctor}} ->
          Mix.shell().info("browser doctor: #{doctor.live_check_status}")
          Mix.shell().info(Jason.encode!(doctor))

        {:ok, response} ->
          Mix.shell().error(
            "browser doctor failed: #{inspect(response.error || response.status)}"
          )
      end
    end)
  end

  def run(["sessions", "list" | _rest]) do
    Mix.Task.run("app.start")

    with_ready_context(fn context ->
      case Runner.run("browser_list_sessions", %{}, context) do
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
          Mix.shell().error(
            "browser sessions list failed: #{inspect(response.error || response.status)}"
          )
      end
    end)
  end

  def run(["sessions", "close", session_id | _rest]) do
    Mix.Task.run("app.start")

    with_ready_context(fn context ->
      case Runner.run("browser_close_session", %{session_id: session_id}, context) do
        {:ok, %{status: :completed}} ->
          Mix.shell().info("browser session closed: #{session_id}")

        {:ok, response} ->
          Mix.shell().error(
            "browser session close failed: #{inspect(response.error || response.status)}"
          )
      end
    end)
  end

  def run(["research", url | rest]) do
    Mix.Task.run("app.start")

    {opts, extra, invalid} = OptionParser.parse(rest, strict: [extract_format: :string])

    cond do
      invalid != [] ->
        Mix.shell().error("browser research failed: invalid options #{inspect(invalid)}")

      extra != [] ->
        Mix.shell().error(
          "browser research failed: unexpected arguments #{Enum.join(extra, " ")}"
        )

      true ->
        with_ready_context(fn context ->
          research(url, Keyword.get(opts, :extract_format, "text"), context)
        end)
    end
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix allbert.browser doctor
      mix allbert.browser research <url> [--extract-format text|markdown|html|pdf]
      mix allbert.browser sessions list
      mix allbert.browser sessions close <session_id>
    """)
  end

  defp research(url, format, context) do
    context = Map.put(context, :confirmation, %{approved?: true})

    with {:ok, %{status: :completed, doctor: %{live_check_status: :ok}}} <-
           Runner.run("browser_doctor", %{}, context),
         {:ok, %{status: :completed, session_id: started_session_id}} <-
           Runner.run("browser_start_session", %{}, context) do
      research_with_session(started_session_id, url, format, context)
    else
      {:ok, response} ->
        Mix.shell().error(
          "browser research failed: #{inspect(response[:error] || response[:status])}"
        )
    end
  end

  defp research_with_session(session_id, url, format, context) do
    try do
      with {:ok, %{status: :completed}} <-
             Runner.run("browser_navigate", %{session_id: session_id, url: url}, context),
           {:ok, %{status: :completed, extraction: extraction}} <-
             Runner.run(
               "browser_extract",
               %{session_id: session_id, format: format},
               context
             ) do
        Mix.shell().info("browser research completed: #{extraction.cache_ref}")
        Mix.shell().info(String.slice(extraction.text || "", 0, 1_000))
      else
        {:ok, response} ->
          Mix.shell().error(
            "browser research failed: #{inspect(response[:error] || response[:status])}"
          )
      end
    after
      maybe_close_session(session_id, context)
    end
  end

  defp maybe_close_session(nil, _context), do: :ok

  defp maybe_close_session(session_id, context) do
    Runner.run("browser_close_session", %{session_id: session_id}, context)
    :ok
  end

  defp with_ready_context(callback) do
    case EffectGuard.admit_ready() do
      {:ok, epoch} -> callback.(%{actor: "local", channel: :cli, allbert_pack_epoch: epoch})
      {:error, _reason} -> Mix.shell().error("Allbert product is not ready; retry the command.")
    end
  end
end
