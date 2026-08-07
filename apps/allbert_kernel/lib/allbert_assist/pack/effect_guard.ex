defmodule AllbertAssist.Pack.EffectGuard do
  @moduledoc "Liveness guard for public and steady-state Pack effect boundaries."

  alias AllbertAssist.Pack.Readiness

  @type epoch :: %{barrier_pid: pid(), snapshot_digest: String.t()}

  @spec admit_ready(keyword()) :: {:ok, epoch()} | {:error, :product_not_ready}
  def admit_ready(opts \\ []) do
    case Readiness.status(opts) do
      {:ok, %{phase: :ready, barrier_pid: pid, snapshot_digest: digest}}
      when is_pid(pid) and is_binary(digest) ->
        {:ok, %{barrier_pid: pid, snapshot_digest: digest}}

      _ ->
        {:error, :product_not_ready}
    end
  end

  @spec validate(term(), keyword()) :: :ok | {:error, :product_not_ready | :stale_epoch}
  def validate(epoch, opts \\ [])

  def validate(%{barrier_pid: barrier_pid, snapshot_digest: digest} = epoch, opts)
      when map_size(epoch) == 2 and is_pid(barrier_pid) and is_binary(digest) do
    case Readiness.status(opts) do
      {:ok, %{phase: :ready, barrier_pid: ^barrier_pid, snapshot_digest: ^digest}} -> :ok
      {:ok, %{phase: :ready}} -> {:error, :stale_epoch}
      _ -> {:error, :product_not_ready}
    end
  end

  def validate(_epoch, _opts), do: {:error, :product_not_ready}
end
