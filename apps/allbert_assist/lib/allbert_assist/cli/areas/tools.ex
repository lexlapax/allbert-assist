defmodule AllbertAssist.CLI.Areas.Tools do
  @moduledoc """
  Release-safe `tools` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.tools` and `allbert admin tools`:
  `dispatch/2` parses the sub-argv, routes to the same registered action the
  Mix task used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls,
  so it runs inside the packaged release. `Mix.Tasks.Allbert.Tools` is a thin
  wrapper that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin tools find "settings"
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin tools")

  defp route(["find" | query_parts], ctx) do
    query =
      query_parts
      |> Enum.join(" ")
      |> String.trim()

    with {:ok, response} <- completed_action("find_tools", %{query: query}, ctx) do
      {:ok, response}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, %{candidates: candidates} = response}) do
    Render.ok(
      [response.message] ++
        Enum.flat_map(candidates, fn candidate ->
          [
            "- #{candidate.source} #{candidate.name} usable_now=#{candidate.usable_now?} requires=#{candidate.requires}"
          ] ++
            if candidate.description != "" do
              ["  #{candidate.description}"]
            else
              []
            end
        end) ++
        Enum.map(Map.get(response, :diagnostics, []), fn diagnostic ->
          "diagnostic=#{diagnostic.source}: #{diagnostic.reason}"
        end)
    )
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}), do: Render.error("Tools command failed: #{inspect(reason)}")

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end
end
