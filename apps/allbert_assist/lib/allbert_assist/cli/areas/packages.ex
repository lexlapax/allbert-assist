defmodule AllbertAssist.CLI.Areas.Packages do
  @moduledoc """
  Release-safe `packages` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.packages` and
  `allbert admin packages`: `dispatch/2` parses the sub-argv, plans or requests
  confirmed package-manager installs through the same `plan_package_install` /
  `run_package_install` actions the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Packages` is a thin wrapper that prints
  the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

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

  @usage """
  Usage:
    allbert admin packages plan MANAGER --cwd PATH --package SPEC [--save-mode MODE]
    allbert admin packages run MANAGER --cwd PATH --package SPEC [--timeout MS]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin packages")

  defp route([command, manager | args], ctx) when command in ["plan", "run"] do
    with {:ok, params} <- parse_args(args, command) do
      params
      |> Map.put(:manager, manager)
      |> run_action(command, ctx)
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp parse_args(args, command) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      invalid != [] ->
        {:error, "Invalid option(s): #{inspect(invalid)}"}

      argv != [] ->
        {:error, "Unexpected argument(s): #{inspect(argv)}"}

      Keyword.get_values(opts, :package) == [] ->
        {:error, "#{command} requires at least one --package SPEC option."}

      true ->
        {:ok,
         opts
         |> Map.new()
         |> Map.put(:packages, Keyword.get_values(opts, :package))
         |> Map.delete(:package)
         |> normalize_timeout()}
    end
  end

  defp normalize_timeout(%{timeout: timeout} = params) do
    params
    |> Map.delete(:timeout)
    |> Map.put(:timeout_ms, timeout)
  end

  defp normalize_timeout(params), do: params

  defp run_action(params, "plan", ctx), do: Runner.run("plan_package_install", params, ctx)
  defp run_action(params, "run", ctx), do: Runner.run("run_package_install", params, ctx)

  defp render({:ok, response}), do: Render.ok(package_lines(response))
  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}) when is_binary(reason), do: Render.error(reason)

  defp package_lines(response) do
    ["Status: #{response.status}", response.message] ++
      confirmation_lines(response) ++
      package_plan_lines(response) ++
      result_summary_lines(response)
  end

  defp confirmation_lines(response) do
    case Map.get(response, :confirmation_id) do
      nil -> []
      id -> ["Confirmation: #{id}"]
    end
  end

  defp package_plan_lines(response) do
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
      |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
    else
      []
    end
  end

  defp result_summary_lines(response) do
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
        |> Enum.map(fn {label, value} ->
          "#{label}: #{String.trim_trailing(to_string(value))}"
        end)

      _other ->
        []
    end
  end

  defp ms_text(nil), do: nil
  defp ms_text(value), do: "#{value}ms"

  defp bytes_text(nil), do: nil
  defp bytes_text(value), do: "#{value} bytes"

  defp denial_text(nil), do: nil
  defp denial_text(reason), do: inspect(reason)
end
