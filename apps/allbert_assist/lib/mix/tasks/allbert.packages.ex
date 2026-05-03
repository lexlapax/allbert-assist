defmodule Mix.Tasks.Allbert.Packages do
  @moduledoc """
  Plan and request confirmed package-manager installs.

  ## Usage

      mix allbert.packages plan npm --cwd /path/to/project --package left-pad@1.3.0
      mix allbert.packages run npm --cwd /path/to/project --package left-pad@1.3.0

  `plan` never runs a package manager. `run` creates a durable confirmation and
  only the approved npm path can execute in v0.10.
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Plan or request confirmed package installs"
  @switches [
    cwd: :string,
    project_root: :string,
    package: :keep,
    version: :string,
    save_mode: :string,
    timeout: :integer,
    timeout_ms: :integer,
    max_output_bytes: :integer,
    source_text: :string
  ]

  @impl true
  def run([command, manager | args]) when command in ["plan", "run"] do
    Mix.Task.run("app.start")

    args
    |> parse_args(command)
    |> Map.put(:manager, manager)
    |> run_action(command)
    |> print_result()
  end

  def run(_args), do: Mix.raise(usage())

  defp parse_args(args, command) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("Unexpected argument(s): #{inspect(argv)}")

      Keyword.get_values(opts, :package) == [] ->
        Mix.raise("#{command} requires at least one --package SPEC option.")

      true ->
        opts
        |> Map.new()
        |> Map.put(:packages, Keyword.get_values(opts, :package))
        |> Map.delete(:package)
        |> normalize_timeout()
    end
  end

  defp normalize_timeout(%{timeout: timeout} = params) do
    params
    |> Map.delete(:timeout)
    |> Map.put(:timeout_ms, timeout)
  end

  defp normalize_timeout(params), do: params

  defp run_action(params, "plan"), do: Runner.run("plan_package_install", params, context())
  defp run_action(params, "run"), do: Runner.run("run_package_install", params, context())

  defp print_result({:ok, response}) do
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info(response.message)
    print_confirmation(response)
    print_package_plan(response)
    print_result_summary(response)
    :ok
  end

  defp print_confirmation(response) do
    case Map.get(response, :confirmation_id) do
      nil -> :ok
      id -> Mix.shell().info("Confirmation: #{id}")
    end
  end

  defp print_package_plan(response) do
    plan = Map.get(response, :install_plan) || Map.get(response, :package_install)

    if is_map(plan) do
      [
        {"Manager", Map.get(plan, :manager)},
        {"Packages", plan |> Map.get(:packages, []) |> Enum.join(", ")},
        {"Target root", Map.get(plan, :resolved_target_root) || Map.get(plan, :target_root)},
        {"Dry-run argv", plan |> Map.get(:dry_run_argv, []) |> Enum.join(" ")},
        {"Execution argv", plan |> Map.get(:execution_argv_preview, []) |> Enum.join(" ")},
        {"Execution available", Map.get(plan, :execution_available?)},
        {"Timeout", ms_text(Map.get(plan, :timeout_ms))},
        {"Output cap", bytes_text(Map.get(plan, :max_output_bytes))},
        {"Warnings", plan |> Map.get(:warnings, []) |> Enum.join(" ")},
        {"Denial", denial_text(Map.get(plan, :denial_reason))}
      ]
      |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
      |> Enum.each(fn {label, value} -> Mix.shell().info("#{label}: #{value}") end)
    end
  end

  defp print_result_summary(response) do
    case Map.get(response, :result) do
      result when is_map(result) ->
        [
          {"Result", Map.get(result, :status)},
          {"Exit", Map.get(result, :exit_status)},
          {"Timed out", Map.get(result, :timed_out?)},
          {"Truncated", Map.get(result, :truncated?)},
          {"Output bytes", Map.get(result, :output_bytes)},
          {"Output preview", Map.get(result, :stdout_preview)}
        ]
        |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
        |> Enum.each(fn {label, value} ->
          Mix.shell().info("#{label}: #{String.trim_trailing(to_string(value))}")
        end)

      _other ->
        :ok
    end
  end

  defp ms_text(nil), do: nil
  defp ms_text(value), do: "#{value}ms"

  defp bytes_text(nil), do: nil
  defp bytes_text(value), do: "#{value} bytes"

  defp denial_text(nil), do: nil
  defp denial_text(reason), do: inspect(reason)

  defp context do
    %{actor: "local", channel: :cli, surface: "mix allbert.packages"}
  end

  defp usage do
    """
    Usage:
      mix allbert.packages plan MANAGER --cwd PATH --package SPEC [--save-mode MODE]
      mix allbert.packages run MANAGER --cwd PATH --package SPEC [--timeout MS]
    """
  end
end
