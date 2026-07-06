defmodule AllbertAssist.CLI.Areas.Exec do
  @moduledoc """
  Release-safe `exec` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.exec` and `allbert admin exec`:
  `dispatch/2` parses the sub-argv, requests confirmed local shell execution
  through the same `run_shell_command` action the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Exec` is a thin wrapper that prints the
  output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Surfaces.ContextBuilder

  @switches [
    cwd: :string,
    timeout: :integer,
    max_output_bytes: :integer
  ]

  @usage """
  Usage:
    allbert admin exec [--cwd PATH] [--timeout MS] [--max-output-bytes BYTES] -- EXECUTABLE [ARGS...]
    allbert admin exec EXECUTABLE [ARGS...]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin exec")

  defp route(argv, ctx) do
    with {:ok, {opts, command_args}} <- parse_args(argv),
         {:ok, response} <- run_command({opts, command_args}, ctx) do
      {:ok, response}
    end
  end

  defp parse_args(args) do
    {option_args, command_args} = split_option_args(args)

    {opts, rest, invalid} = OptionParser.parse(option_args, strict: @switches)

    cond do
      invalid != [] ->
        {:error, "Invalid option(s): #{inspect(invalid)}"}

      rest != [] ->
        {:error, "Use -- before command arguments when passing task options."}

      command_args == [] ->
        {:usage, @usage}

      true ->
        {:ok, {opts, command_args}}
    end
  end

  defp split_option_args(args) do
    if "--" in args do
      split_on_separator(args)
    else
      split_without_separator(args)
    end
  end

  defp split_on_separator(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {option_args, ["--" | command_args]} -> {option_args, command_args}
    end
  end

  defp split_without_separator([first | _rest] = args) do
    if starts_with_dash?(first), do: {args, []}, else: {[], args}
  end

  defp split_without_separator([]), do: {[], []}

  defp starts_with_dash?("-" <> _rest), do: true
  defp starts_with_dash?(_arg), do: false

  defp run_command({opts, [executable | args]}, ctx) do
    params =
      %{
        executable: executable,
        args: args,
        cwd: opts[:cwd] || File.cwd!()
      }
      |> maybe_put(:timeout_ms, opts[:timeout])
      |> maybe_put(:max_output_bytes, opts[:max_output_bytes])

    Runner.run("run_shell_command", params, ctx)
  end

  defp render({:ok, response}), do: Render.ok(exec_lines(response))
  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}) when is_binary(reason), do: Render.error(reason)

  defp exec_lines(response) do
    ["Status: #{response.status}", response.message] ++
      confirmation_lines(response) ++
      command_lines(response) ++
      result_summary_lines(response)
  end

  defp confirmation_lines(response) do
    case Map.get(response, :confirmation_id) do
      nil -> []
      id -> ["Confirmation: #{id}"]
    end
  end

  defp command_lines(response) do
    confirmation = Map.get(response, :confirmation)

    if is_map(confirmation) do
      ShellCommandMetadata.command_details(confirmation)
    else
      response_command_lines(response)
    end
  end

  defp response_command_lines(response) do
    command = Map.get(response, :command, %{})

    [
      {"Command", command_line(command)},
      {"Cwd", Map.get(command, :resolved_cwd) || Map.get(command, :cwd)},
      {"Sandbox", sandbox_text(Map.get(command, :sandbox_level))},
      {"Timeout", ms_text(Map.get(command, :timeout_ms))},
      {"Output cap", bytes_text(Map.get(command, :max_output_bytes))},
      {"Denial", denial_text(Map.get(command, :denial_reason))}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)
  end

  defp result_summary_lines(response) do
    case Map.get(response, :result) do
      result when is_map(result) -> result_lines(result)
      _other -> []
    end
  end

  defp result_lines(result) do
    [
      {"Result", Map.get(result, :status)},
      {"Exit", Map.get(result, :exit_status)},
      {"Timed out", Map.get(result, :timed_out?)},
      {"Truncated", Map.get(result, :truncated?)},
      {"Output bytes", Map.get(result, :output_bytes)},
      {"Output preview", Map.get(result, :stdout_preview)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map(fn {label, value} -> "#{label}: #{String.trim_trailing(to_string(value))}" end)
  end

  defp command_line(command) when is_map(command) do
    executable = Map.get(command, :executable)
    args = Map.get(command, :args, [])

    if is_binary(executable), do: Enum.join([executable | args], " "), else: nil
  end

  defp sandbox_text(nil), do: nil
  defp sandbox_text(level), do: "level #{level}"

  defp ms_text(nil), do: nil
  defp ms_text(value), do: "#{value}ms"

  defp bytes_text(nil), do: nil
  defp bytes_text(value), do: "#{value} bytes"

  defp denial_text(nil), do: nil
  defp denial_text(reason), do: inspect(reason)

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
