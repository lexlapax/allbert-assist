defmodule Mix.Tasks.Allbert.TuiTest do
  use ExUnit.Case, async: false
  @moduletag :db_serial

  alias AllbertAssist.Repo
  alias Mix.Tasks.Allbert.Tui

  setup do
    original_logger_level = Logger.level()
    original_primary_level = :logger.get_primary_config() |> Map.fetch!(:level)
    original_logger_config_level = Application.get_env(:logger, :level)
    original_repo_config = Application.get_env(:allbert_assist, Repo)
    original_tui_log_level = System.get_env("ALLBERT_TUI_LOG_LEVEL")

    on_exit(fn ->
      restore_system_env("ALLBERT_TUI_LOG_LEVEL", original_tui_log_level)
      restore_logger_level_config(original_logger_config_level)
      Logger.configure(level: original_logger_level)
      _result = :logger.set_primary_config(:level, original_primary_level)
      restore_app_env(Repo, original_repo_config)
    end)

    :ok
  end

  test "configures quiet operator logging by default" do
    System.delete_env("ALLBERT_TUI_LOG_LEVEL")
    Application.put_env(:allbert_assist, Repo, database: "tmp/allbert-test.sqlite3", log: :debug)

    assert :ok = Tui.configure_operator_logging!()

    assert Logger.level() == :warning
    assert Application.get_env(:logger, :level) == :warning
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :warning
    assert Application.get_env(:allbert_assist, Repo)[:log] == false
  end

  test "honors explicit TUI log level" do
    System.put_env("ALLBERT_TUI_LOG_LEVEL", "debug")

    assert :ok = Tui.configure_operator_logging!()

    assert Logger.level() == :debug
    assert Application.get_env(:logger, :level) == :debug
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :debug
    assert Application.get_env(:allbert_assist, Repo)[:log] == false
  end

  test "rejects invalid TUI log level" do
    System.put_env("ALLBERT_TUI_LOG_LEVEL", "verbose")

    assert_raise Mix.Error, ~r/ALLBERT_TUI_LOG_LEVEL/, fn ->
      Tui.configure_operator_logging!()
    end
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)

  defp restore_logger_level_config(nil), do: Application.delete_env(:logger, :level)
  defp restore_logger_level_config(value), do: Application.put_env(:logger, :level, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
