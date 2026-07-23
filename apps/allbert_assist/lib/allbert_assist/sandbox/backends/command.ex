defmodule AllbertAssist.Sandbox.Backends.Command do
  @moduledoc false

  alias AllbertAssist.Execution.ProcessOwner

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 3000)
    on_timeout = Keyword.get(opts, :on_timeout, fn -> :ok end)

    owner_opts = [
      timeout_ms: timeout_ms,
      max_output_bytes: Keyword.get(opts, :max_output_bytes, 8192),
      env: Keyword.get(opts, :env, []),
      cd: Keyword.get(opts, :cd, File.cwd!()),
      on_timeout: on_timeout,
      execution_id: Keyword.get(opts, :execution_id, Ecto.UUID.generate())
    ]

    case ProcessOwner.run(executable, args, owner_opts) do
      {:ok, %{timed_out?: true}} -> {:error, :timeout}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
