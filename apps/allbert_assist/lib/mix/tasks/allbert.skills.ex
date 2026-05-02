defmodule Mix.Tasks.Allbert.Skills do
  @moduledoc """
  Validate and scaffold local Allbert Agent Skills.

  ## Usage

      mix allbert.skills validate PATH
      mix allbert.skills create NAME ACTION PERMISSION DESCRIPTION... [--root ROOT] [--overwrite]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Validate and scaffold local Allbert Agent Skills"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["validate", path]) do
    with {:ok, response} <- completed_action("validate_skill", %{path: path}) do
      {:ok, {:validation, response.validation}}
    end
  end

  defp dispatch(["create", name, action, permission | rest]) do
    {description_parts, opts} = parse_create_options(rest)

    params =
      %{
        name: name,
        action: action,
        permission: permission,
        description: Enum.join(description_parts, " ")
      }
      |> maybe_put(:root, Map.get(opts, :root))
      |> maybe_put(:overwrite, Map.get(opts, :overwrite))

    with {:ok, response} <- completed_action("create_skill", params) do
      {:ok, {:created, response.skill}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.skills validate PATH
      mix allbert.skills create NAME ACTION PERMISSION DESCRIPTION... [--root ROOT] [--overwrite]
    """)
  end

  defp print_result({:ok, {:validation, validation}}) do
    Mix.shell().info("Validation: #{validation.status}")
    Mix.shell().info("Path: #{validation.path}")
    Mix.shell().info("Name: #{validation.name || "unknown"}")
    Mix.shell().info("Contract: #{validation.contract.validation_status}")
    Mix.shell().info("Execution eligible: #{validation.contract.execution_eligible?}")
    print_diagnostics(validation.diagnostics)
  end

  defp print_result({:ok, {:created, skill}}) do
    Mix.shell().info("Created: #{skill.skill_md_path}")
    print_result({:ok, {:validation, skill.validation}})
  end

  defp print_result({:error, reason}) do
    Mix.raise("Skills command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp parse_create_options(args) do
    parse_create_options(args, [], %{})
  end

  defp parse_create_options(["--root", root | rest], description, opts) do
    parse_create_options(rest, description, Map.put(opts, :root, root))
  end

  defp parse_create_options(["--overwrite" | rest], description, opts) do
    parse_create_options(rest, description, Map.put(opts, :overwrite, true))
  end

  defp parse_create_options([part | rest], description, opts) do
    parse_create_options(rest, [part | description], opts)
  end

  defp parse_create_options([], description, opts), do: {Enum.reverse(description), opts}

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp context do
    %{actor: "local", channel: :cli, selected_skill: nil}
  end

  defp print_diagnostics([]), do: Mix.shell().info("Diagnostics: none")

  defp print_diagnostics(diagnostics) do
    Mix.shell().info("Diagnostics:")

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info("- #{diagnostic.severity} #{diagnostic.code}: #{diagnostic.message}")
    end)
  end
end
