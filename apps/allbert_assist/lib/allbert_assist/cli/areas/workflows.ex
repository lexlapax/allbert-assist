defmodule AllbertAssist.CLI.Areas.Workflows do
  @moduledoc """
  Release-safe `workflows` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.workflows` and
  `allbert admin workflows`: `dispatch/2` parses the sub-argv, routes to the same
  registered actions the Mix task used, and returns `{rendered_output, exit_code}`
  — no `Mix.*` calls, so it runs inside the packaged release.
  `Mix.Tasks.Allbert.Workflows` is a thin wrapper that prints the output through
  `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage_exit 64
  @dialyzer {:nowarn_function, [fail!: 2]}

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin workflows")

  defp route(argv, ctx) do
    do_route(argv, ctx)
  catch
    {:workflow_error, _code, message} -> {:usage, message}
  end

  defp do_route(["list"], ctx) do
    with {:ok, response} <- Runner.run("list_workflows", %{}, ctx) do
      {:ok, {:list, get_in(response, [:output_data, :workflows]) || []}}
    end
  end

  defp do_route(["inspect", workflow_id], ctx) do
    with {:ok, response} <- Runner.run("inspect_workflow", %{workflow_id: workflow_id}, ctx) do
      {:ok, {:inspect, response}}
    end
  end

  defp do_route(["expand", workflow_id | args], ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [input: :keep])
    reject_invalid!(invalid)
    reject_rest!(rest, "expand")

    inputs =
      opts
      |> Keyword.get_values(:input)
      |> Map.new(&parse_input!/1)

    with {:ok, response} <-
           Runner.run("expand_workflow", %{workflow_id: workflow_id, inputs: inputs}, ctx) do
      {:ok, {:expand, response}}
    end
  end

  defp do_route(_args, _ctx) do
    fail!(
      @usage_exit,
      """
      Usage:
        mix allbert.workflows list
        mix allbert.workflows inspect WORKFLOW_ID
        mix allbert.workflows expand WORKFLOW_ID --input key=value
      """
    )
  end

  defp render({:ok, {:list, []}}), do: Render.ok("No workflows.")

  defp render({:ok, {:list, workflows}}) do
    Render.ok(Enum.map(workflows, fn workflow -> "#{workflow.id} size=#{workflow.size}" end))
  end

  defp render({:ok, {:inspect, %{status: :completed, output_data: %{workflow: workflow}}}}) do
    Render.ok([
      "Workflow #{workflow["id"]} is valid.",
      "Steps: #{length(workflow["steps"] || [])}"
    ])
  end

  defp render({:ok, {:inspect, response}}), do: fail_response(response)

  defp render({:ok, {:expand, %{status: :completed, output_data: output_data}}}) do
    Render.ok("Expanded steps: #{output_data.step_count}")
  end

  defp render({:ok, {:expand, response}}), do: fail_response(response)

  defp render({:usage, message}), do: Render.usage(message)

  defp parse_input!(value) do
    case String.split(value, "=", parts: 2) do
      [key, parsed] when key != "" -> {key, parsed}
      _other -> fail!(@usage_exit, "--input must be key=value")
    end
  end

  defp fail_response(%{output_data: %{error: %{reason: :workflow_not_found}}}) do
    Render.error("Workflow not found.")
  end

  defp fail_response(%{output_data: %{error: error}}), do: Render.error(inspect(error))
  defp fail_response(response), do: Render.error(inspect(response))

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Invalid options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: fail!(@usage_exit, "Unexpected #{command} args: #{inspect(rest)}")

  defp fail!(code, message), do: throw({:workflow_error, code, message})
end
