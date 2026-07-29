defmodule Mix.Tasks.Allbert.Tui do
  @moduledoc """
  Run the local Allbert terminal TUI channel.

  ## Usage

      ERL_AFLAGS="${ERL_AFLAGS:+$ERL_AFLAGS }+Bc" mix allbert.tui
      mix allbert.tui --input-driver-proof

  The packaged `allbert tui` launcher applies the scoped OTP `+Bc` posture
  automatically. Source TUI sessions include it so Ctrl-C reaches the raw input
  driver instead of the emulator break handler. The non-interactive input proof
  does not require it.
  """

  use Mix.Task

  alias AllbertAssist.Channels.TUI.InputDriver
  alias AllbertAssist.CLI.Tui, as: ReleaseTui

  @shortdoc "Run the local Allbert terminal TUI"

  @impl true
  def run(args) do
    case args do
      [] ->
        Mix.Task.run("app.config")
        launch_client!()

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
  def launch_client!(launch_fun \\ &ReleaseTui.launch/0) when is_function(launch_fun, 0) do
    case launch_fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise(ReleaseTui.error_message(reason))

      other ->
        Mix.raise("TUI client exited unexpectedly: #{inspect(other)}")
    end
  end

  @doc false
  def configure_operator_logging! do
    case ReleaseTui.configure_operator_logging() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(ReleaseTui.error_message(reason))
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
