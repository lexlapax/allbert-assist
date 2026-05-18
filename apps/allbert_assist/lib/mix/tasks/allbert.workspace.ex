defmodule Mix.Tasks.Allbert.Workspace do
  @moduledoc """
  Inspect and maintain the Allbert workspace substrate.

  ## Usage

      mix allbert.workspace rotate-signing-secret
      mix allbert.workspace inspect [--user USER] [--thread THREAD]
  """

  use Mix.Task

  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
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

  defp dispatch(["inspect" | args]) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [user: :string, thread: :string],
        aliases: [u: :user, t: :thread]
      )

    case invalid do
      [] -> {:ok, {:inspect, opts}}
      _invalid -> {:error, :invalid_inspect_options}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.workspace rotate-signing-secret
      mix allbert.workspace inspect [--user USER] [--thread THREAD]
    """)
  end

  defp print_result({:ok, {:inspect, opts}}) do
    user_id = Keyword.get(opts, :user, "local")
    thread_id = Keyword.get(opts, :thread, "local-default")
    surface = Catalog.workspace_tree(user_id: user_id, thread_id: thread_id)

    Mix.shell().info("Resolved workspace Surface tree")
    Mix.shell().info("Surface: #{inspect(surface.id)} #{surface.path} kind=#{surface.kind}")
    Mix.shell().info("workspace.theme=#{workspace_theme()}")
    Mix.shell().info("user_id=#{user_id} thread_id=#{thread_id}")

    Enum.each(surface.nodes, &print_node(&1, 0))
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

  defp workspace_theme do
    case Settings.get("workspace.theme") do
      {:ok, theme} -> theme
      _other -> "system"
    end
  end

  defp print_node(%Node{} = node, depth) do
    indent = String.duplicate("  ", depth)
    Mix.shell().info("#{indent}- #{node.id} #{node.component}")
    Enum.each(node.children, &print_node(&1, depth + 1))
  end
end
