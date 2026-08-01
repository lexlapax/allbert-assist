defmodule Mix.Tasks.Allbert do
  @moduledoc """
  Run the unified Allbert operator CLI from a source checkout.

  Ordinary commands use the same `AllbertAssist.CLI.run_entry/1` boundary as
  the packaged binary. That boundary attaches to a running daemon before it
  considers an embedded runtime, preserving the single-writer contract.

  Interactive source commands delegate to their existing launchers:

      mix allbert tui
      mix allbert serve
  """

  use Mix.Task

  alias AllbertAssist.CLI

  @shortdoc "Run the unified Allbert CLI from source"

  @impl true
  def run(["tui" | args]), do: Mix.Task.run("allbert.tui", args)

  def run(["serve" | args]) do
    with_source_daemon_env(fn ->
      # `phx.server` delegates to `mix run`, whose application-config load would
      # otherwise restore dev's :debug level after our daemon boundary. Load it
      # once while the source-daemon environment is active, then make :info (or
      # the validated override) authoritative before applications start.
      Mix.Task.run("app.config")
      CLI.configure_daemon_logging()
      Mix.Task.run("phx.server", args)
    end)
  end

  def run(args) do
    CLI.configure_logging()

    # Load application configuration without starting Allbert. Runtime commands
    # must get their first chance to execute through CLI.run_entry/1's attach
    # transport, exactly like the packaged binary.
    Mix.Task.run("app.config")

    case CLI.run_entry(args) do
      {:stdout, output, 0} ->
        if output != "", do: Mix.shell().info(output)
        :ok

      {_stream, output, _code} ->
        Mix.raise(output)
    end
  end

  defp with_source_daemon_env(fun) do
    previous_phx_server = System.get_env("PHX_SERVER")
    previous_writer_lock = System.get_env("ALLBERT_HOLD_WRITER_LOCK")

    System.put_env("PHX_SERVER", "true")
    System.put_env("ALLBERT_HOLD_WRITER_LOCK", "1")

    try do
      fun.()
    after
      restore_env("PHX_SERVER", previous_phx_server)
      restore_env("ALLBERT_HOLD_WRITER_LOCK", previous_writer_lock)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
