defmodule Mix.Tasks.Allbert.Tools do
  @moduledoc """
  Find Allbert tool candidates.

  ## Usage

      mix allbert.tools find "settings"
  """

  use Mix.Task

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Find Allbert tool candidates"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["find" | query_parts]) do
    query =
      query_parts
      |> Enum.join(" ")
      |> String.trim()

    with {:ok, response} <- completed_action("find_tools", %{query: query}) do
      {:ok, response}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.tools find "settings"
    """)
  end

  defp completed_action(action_name, params) do
    ActionHelper.completed_action(action_name, params, context())
  end

  defp print_result({:ok, %{candidates: candidates} = response}) do
    Mix.shell().info(response.message)

    Enum.each(candidates, fn candidate ->
      Mix.shell().info(
        "- #{candidate.source} #{candidate.name} usable_now=#{candidate.usable_now?} requires=#{candidate.requires}"
      )

      if candidate.description != "" do
        Mix.shell().info("  #{candidate.description}")
      end
    end)

    diagnostics = Map.get(response, :diagnostics, [])

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info("diagnostic=#{diagnostic.source}: #{diagnostic.reason}")
    end)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Tools command failed: #{inspect(reason)}")
  end

  defp context, do: ContextBuilder.cli_context(surface: "mix allbert.tools")
end
