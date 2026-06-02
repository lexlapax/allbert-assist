defmodule Mix.Tasks.Allbert.Workflows do
  @moduledoc """
  Inspect and expand v0.44 workflow YAML files.

  ## Usage

      mix allbert.workflows list
      mix allbert.workflows inspect WORKFLOW_ID
      mix allbert.workflows expand WORKFLOW_ID --input key=value
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect v0.44 workflow YAML"
  @usage_exit 64
  @not_found_exit 65
  @failure_exit 1
  @dialyzer {:nowarn_function, [fail_response: 1, fail!: 2]}

  @impl true
  def run(args) do
    try do
      Mix.Task.run("app.start")

      args
      |> dispatch()
      |> print_result()
    catch
      {:workflow_error, code, message} ->
        Mix.shell().error(message)
        System.halt(code)
    end
  end

  defp dispatch(["list"]) do
    with {:ok, response} <- Runner.run("list_workflows", %{}, context()) do
      {:ok, {:list, get_in(response, [:output_data, :workflows]) || []}}
    end
  end

  defp dispatch(["inspect", workflow_id]) do
    with {:ok, response} <- Runner.run("inspect_workflow", %{workflow_id: workflow_id}, context()) do
      {:ok, {:inspect, response}}
    end
  end

  defp dispatch(["expand", workflow_id | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [input: :keep])
    reject_invalid!(invalid)
    reject_rest!(rest, "expand")

    inputs =
      opts
      |> Keyword.get_values(:input)
      |> Map.new(&parse_input!/1)

    with {:ok, response} <-
           Runner.run("expand_workflow", %{workflow_id: workflow_id, inputs: inputs}, context()) do
      {:ok, {:expand, response}}
    end
  end

  defp dispatch(_args) do
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

  defp print_result({:ok, {:list, []}}), do: Mix.shell().info("No workflows.")

  defp print_result({:ok, {:list, workflows}}) do
    Enum.each(workflows, fn workflow ->
      Mix.shell().info("#{workflow.id} size=#{workflow.size}")
    end)
  end

  defp print_result({:ok, {:inspect, %{status: :completed, output_data: %{workflow: workflow}}}}) do
    Mix.shell().info("Workflow #{workflow["id"]} is valid.")
    Mix.shell().info("Steps: #{length(workflow["steps"] || [])}")
  end

  defp print_result({:ok, {:inspect, response}}), do: fail_response(response)

  defp print_result({:ok, {:expand, %{status: :completed, output_data: output_data}}}) do
    Mix.shell().info("Expanded steps: #{output_data.step_count}")
  end

  defp print_result({:ok, {:expand, response}}), do: fail_response(response)

  defp parse_input!(value) do
    case String.split(value, "=", parts: 2) do
      [key, parsed] when key != "" -> {key, parsed}
      _other -> fail!(@usage_exit, "--input must be key=value")
    end
  end

  defp fail_response(%{output_data: %{error: %{reason: :workflow_not_found}}}) do
    fail!(@not_found_exit, "Workflow not found.")
  end

  defp fail_response(%{output_data: %{error: error}}), do: fail!(@failure_exit, inspect(error))
  defp fail_response(response), do: fail!(@failure_exit, inspect(response))

  defp context, do: %{actor: "local", user_id: "local", channel: :cli}

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Invalid options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: fail!(@usage_exit, "Unexpected #{command} args: #{inspect(rest)}")

  defp fail!(code, message), do: throw({:workflow_error, code, message})
end
