defmodule Mix.Tasks.Allbert.TuiTest do
  use ExUnit.Case, async: false
  @moduletag :db_serial

  alias AllbertAssist.CLI.Tui, as: ReleaseTui
  alias Mix.Tasks.Allbert.Tui

  setup do
    original_logger_level = Logger.level()
    original_primary_level = :logger.get_primary_config() |> Map.fetch!(:level)
    original_logger_config_level = Application.get_env(:logger, :level)
    original_tui_log_level = System.get_env("ALLBERT_TUI_LOG_LEVEL")

    on_exit(fn ->
      restore_system_env("ALLBERT_TUI_LOG_LEVEL", original_tui_log_level)
      restore_logger_level_config(original_logger_config_level)
      Logger.configure(level: original_logger_level)
      _result = :logger.set_primary_config(:level, original_primary_level)
    end)

    :ok
  end

  test "configures quiet operator logging by default" do
    System.delete_env("ALLBERT_TUI_LOG_LEVEL")

    assert :ok = Tui.configure_operator_logging!()

    assert Logger.level() == :warning
    assert Application.get_env(:logger, :level) == :warning
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :warning
  end

  test "honors explicit TUI log level" do
    System.put_env("ALLBERT_TUI_LOG_LEVEL", "debug")

    assert :ok = Tui.configure_operator_logging!()

    assert Logger.level() == :debug
    assert Application.get_env(:logger, :level) == :debug
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :debug
  end

  test "rejects invalid TUI log level" do
    System.put_env("ALLBERT_TUI_LOG_LEVEL", "verbose")

    assert {:error, {:invalid_tui_log_level, "verbose"}} = ReleaseTui.launch()

    assert_raise Mix.Error, ~r/ALLBERT_TUI_LOG_LEVEL/, fn ->
      Tui.configure_operator_logging!()
    end
  end

  test "development launcher delegates to the shared attach-only client seam" do
    parent = self()

    assert :ok =
             Tui.launch_client!(fn ->
               send(parent, :shared_client_called)
               :ok
             end)

    assert_receive :shared_client_called
  end

  test "development launcher reports a bounded attach failure" do
    assert_raise Mix.Error, ~r/No Allbert daemon.*allbert serve/s, fn ->
      Tui.launch_client!(fn -> {:error, :not_available} end)
    end
  end

  test "development launcher treats unexpected client returns as failures" do
    assert_raise Mix.Error, ~r/TUI client exited unexpectedly: :shutdown/, fn ->
      Tui.launch_client!(fn -> :shutdown end)
    end
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)

  defp restore_logger_level_config(nil), do: Application.delete_env(:logger, :level)
  defp restore_logger_level_config(value), do: Application.put_env(:logger, :level, value)
end
