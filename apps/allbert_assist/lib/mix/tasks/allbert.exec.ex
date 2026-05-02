defmodule Mix.Tasks.Allbert.Exec do
  @moduledoc """
  Request confirmed local shell execution through the Allbert action boundary.

  ## Usage

      mix allbert.exec ls -la
      mix allbert.exec --cwd /path/to/workspace -- ls -la
      mix allbert.exec --cwd /path --timeout 1000 --max-output-bytes 4096 -- rg allbert .

  This task never runs shell strings. It sends one executable plus argv list to
  `run_shell_command`, which applies v0.08 Level 1 local execution policy and
  creates a durable confirmation before any command can execute.
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations.ShellCommandMetadata

  @shortdoc "Request confirmed local shell execution"
  @switches [
    cwd: :string,
    timeout: :integer,
    max_output_bytes: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> parse_args()
    |> run_command()
    |> print_result()
  end

  defp parse_args(args) do
    {option_args, command_args} = split_option_args(args)

    {opts, rest, invalid} = OptionParser.parse(option_args, strict: @switches)

    cond do
      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      rest != [] ->
        Mix.raise("Use -- before command arguments when passing task options.")

      command_args == [] ->
        Mix.raise(usage())

      true ->
        {opts, command_args}
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

  defp run_command({opts, [executable | args]}) do
    params =
      %{
        executable: executable,
        args: args,
        cwd: opts[:cwd] || File.cwd!()
      }
      |> maybe_put(:timeout_ms, opts[:timeout])
      |> maybe_put(:max_output_bytes, opts[:max_output_bytes])

    Runner.run("run_shell_command", params, context())
  end

  defp print_result({:ok, response}) do
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info(response.message)
    print_confirmation(response)
    print_command(response)
    print_result_summary(response)
    :ok
  end

  defp print_confirmation(response) do
    case Map.get(response, :confirmation_id) do
      nil -> :ok
      id -> Mix.shell().info("Confirmation: #{id}")
    end
  end

  defp print_command(response) do
    confirmation = Map.get(response, :confirmation)

    if is_map(confirmation) do
      Enum.each(ShellCommandMetadata.command_details(confirmation), fn line ->
        Mix.shell().info(line)
      end)
    else
      response
      |> response_command_lines()
      |> Enum.each(fn line -> Mix.shell().info(line) end)
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

  defp print_result_summary(response) do
    case Map.get(response, :result) do
      result when is_map(result) ->
        Enum.each(result_lines(result), fn line -> Mix.shell().info(line) end)

      _other ->
        :ok
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

  defp context do
    %{actor: "local", channel: :cli, surface: "mix allbert.exec"}
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp usage do
    """
    Usage:
      mix allbert.exec [--cwd PATH] [--timeout MS] [--max-output-bytes BYTES] -- EXECUTABLE [ARGS...]
      mix allbert.exec EXECUTABLE [ARGS...]
    """
  end
end
