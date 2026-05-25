defmodule AllbertAssist.Sandbox.Backends.Command do
  @moduledoc false

  alias AllbertAssist.Execution.OutputBuffer

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 3000)
    on_timeout = Keyword.get(opts, :on_timeout, fn -> :ok end)

    executable
    |> run_task(args, opts)
    |> await(timeout_ms, on_timeout)
  end

  defp run_task(executable, args, opts) do
    Task.async(fn ->
      try do
        max_output_bytes = Keyword.get(opts, :max_output_bytes, 8192)
        buffer = OutputBuffer.new(max_output_bytes)

        command_opts =
          [
            stderr_to_stdout: true,
            into: buffer,
            env: Keyword.get(opts, :env, [])
          ]
          |> maybe_put_cd(Keyword.get(opts, :cd))

        {output_buffer, exit_status} = System.cmd(executable, args, command_opts)
        output = OutputBuffer.output(output_buffer)

        {:ok,
         %{
           exit_status: exit_status,
           output: output,
           truncated?: output_buffer.truncated?,
           output_bytes: byte_size(output)
         }}
      rescue
        exception -> {:error, {exception.__struct__, Exception.message(exception)}}
      end
    end)
  end

  defp await(task, timeout_ms, on_timeout) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        safe_timeout_callback(on_timeout)
        {:error, :timeout}
    end
  end

  defp safe_timeout_callback(on_timeout) do
    on_timeout.()
  rescue
    _exception -> :ok
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd), do: Keyword.put(opts, :cd, cd)
end
