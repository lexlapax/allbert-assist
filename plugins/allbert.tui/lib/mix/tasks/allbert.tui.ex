defmodule Mix.Tasks.Allbert.Tui do
  @moduledoc """
  Run the local Allbert terminal TUI channel.

  ## Usage

      mix allbert.tui
      mix allbert.tui --input-driver-proof
  """

  use Mix.Task

  alias AllbertAssist.Channels.TUI.Adapter
  alias AllbertAssist.Channels.TUI.InputDriver
  alias AllbertAssist.CLI.Tui, as: ReleaseTui
  alias AllbertAssist.PublicProtocol.StdioGuard

  @shortdoc "Run the local Allbert terminal TUI"
  @supervisor AllbertAssist.Channels.Supervisor
  @log_level_help "debug, info, warning, error, or none"
  @silent_log_level :emergency

  @impl true
  def run(args) do
    case args do
      [] ->
        Mix.Task.run("app.config")
        silence_startup_logging!()
        quiet_repo_query_logs!()
        prepare_runtime!()
        configure_operator_logging!()
        wait_for_tui_exit!()
        :ok

      ["--input-driver-proof"] ->
        Mix.Task.run("app.config")
        configure_operator_logging!()
        run_input_driver_proof!()

      _args ->
        Mix.raise("Usage: mix allbert.tui [--input-driver-proof]")
    end
  end

  @doc false
  def readiness_guard(opts \\ []), do: ReleaseTui.readiness_guard(opts)

  @doc false
  def prepare_runtime!(prepare_fun \\ &ReleaseTui.prepare/0) when is_function(prepare_fun, 0) do
    case prepare_fun.() do
      :ok ->
        :ok

      {:error, {:tui_explicitly_disabled, guidance}} ->
        Mix.raise("TUI is disabled. #{guidance}")

      {:error, reason} ->
        Mix.raise("TUI runtime could not start: #{inspect(reason)}")

      other ->
        Mix.raise("TUI runtime could not start: #{inspect(other)}")
    end
  end

  @doc false
  def configure_operator_logging! do
    level = operator_log_level!()

    Application.put_env(:logger, :level, level)
    Logger.configure(level: level)
    _result = :logger.set_primary_config(:level, level)

    quiet_repo_query_logs!()
    :ok
  end

  defp silence_startup_logging! do
    StdioGuard.silence_stdout!()
    Application.put_env(:logger, :level, @silent_log_level)
    Logger.configure(level: @silent_log_level)
    _result = :logger.set_primary_config(:level, @silent_log_level)
    :ok
  end

  defp quiet_repo_query_logs! do
    repo_config =
      :allbert_assist
      |> Application.get_env(AllbertAssist.Repo, [])
      |> normalize_keyword()

    Application.put_env(
      :allbert_assist,
      AllbertAssist.Repo,
      Keyword.put(repo_config, :log, false)
    )

    :ok
  end

  defp operator_log_level! do
    case System.get_env("ALLBERT_TUI_LOG_LEVEL", "warning")
         |> String.trim()
         |> String.downcase() do
      "debug" ->
        :debug

      "info" ->
        :info

      "warning" ->
        :warning

      "warn" ->
        :warning

      "error" ->
        :error

      "none" ->
        @silent_log_level

      "" ->
        :warning

      other ->
        Mix.raise("ALLBERT_TUI_LOG_LEVEL=#{inspect(other)} is invalid; use #{@log_level_help}")
    end
  end

  defp normalize_keyword(opts) when is_list(opts), do: opts
  defp normalize_keyword(_opts), do: []

  defp wait_for_tui_exit! do
    case Adapter.run_supervised_forever(@supervisor) do
      :normal -> :ok
      :shutdown -> :ok
      {:shutdown, _reason} -> :ok
      {:error, reason} -> Mix.raise("TUI channel is not running: #{inspect(reason)}")
      reason -> Mix.raise("TUI channel exited unexpectedly: #{inspect(reason)}")
    end
  end

  defp run_input_driver_proof! do
    Owl.IO.puts("Allbert TUI input-driver proof.")
    Owl.IO.puts("Press Esc to validate single-key capture, or type a line and Enter.")

    case InputDriver.run_proof() do
      :ok -> :ok
      {:error, reason} -> Mix.raise("TUI input-driver proof failed: #{inspect(reason)}")
    end
  end
end
