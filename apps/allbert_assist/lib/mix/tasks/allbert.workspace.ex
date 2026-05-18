defmodule Mix.Tasks.Allbert.Workspace do
  @moduledoc """
  Inspect and maintain the Allbert workspace substrate.

  ## Usage

      mix allbert.workspace rotate-signing-secret
  """

  use Mix.Task

  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @shortdoc "Inspect and maintain the Allbert workspace substrate"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["rotate-signing-secret"]) do
    SigningSecret.rotate()
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.workspace rotate-signing-secret
    """)
  end

  defp print_result({:ok, result}) do
    Mix.shell().info("Rotated workspace fragment signing secret.")
    Mix.shell().info("Path: #{result.path}")
    Mix.shell().info("Fingerprint: #{result.fingerprint}")
    Mix.shell().info("Rotated at: #{DateTime.to_iso8601(result.rotated_at)}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Workspace command failed: #{inspect(reason)}")
  end
end
