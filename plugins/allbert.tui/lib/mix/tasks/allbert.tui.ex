defmodule Mix.Tasks.Allbert.Tui do
  @moduledoc """
  Run the local Allbert terminal TUI channel.

  ## Usage

      mix allbert.tui
  """

  use Mix.Task

  alias AllbertAssist.Channels.TUI.Adapter
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
        enable_supervised_tui_child!()
        Mix.Task.run("app.start")
        configure_operator_logging!()
        wait_for_tui_exit!()
        :ok

      _args ->
        Mix.raise("Usage: mix allbert.tui")
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

  defp enable_supervised_tui_child! do
    opts = Application.get_env(:allbert_assist, @supervisor, [])
    channel_child_opts = opts |> Keyword.get(:channel_child_opts, %{}) |> normalize_child_opts()

    existing_tui_child_opts = Map.get(channel_child_opts, "tui", []) || []

    tui_child_opts =
      Keyword.merge(
        existing_tui_child_opts,
        enabled?: true,
        auto_input?: true,
        emit_banner?: true,
        live_screen?: true,
        restart: :transient
      )

    Application.put_env(
      :allbert_assist,
      @supervisor,
      opts
      |> Keyword.put(:channel_child_opts, Map.put(channel_child_opts, "tui", tui_child_opts))
    )
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

  defp normalize_child_opts(opts) when is_map(opts), do: opts
  defp normalize_child_opts(_opts), do: %{}
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
end
