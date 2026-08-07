defmodule AllbertAssist.Pack.EffectGuard do
  @moduledoc "Liveness guard for public and steady-state Pack effect boundaries."

  alias AllbertAssist.Pack.Readiness

  @type epoch :: %{barrier_pid: pid(), snapshot_digest: String.t()}

  @spec admit_ready(keyword()) :: {:ok, epoch()} | {:error, :product_not_ready}
  def admit_ready(opts \\ []) do
    case Readiness.status(opts) do
      {:ok, %{phase: :ready, barrier_pid: pid, snapshot_digest: digest}}
      when is_pid(pid) and is_binary(digest) ->
        epoch = %{barrier_pid: pid, snapshot_digest: digest}

        case maybe_register_test_epoch(epoch, opts) do
          :ok -> {:ok, epoch}
          {:error, _reason} -> {:error, :product_not_ready}
        end

      _ ->
        {:error, :product_not_ready}
    end
  end

  @spec validate(term(), keyword()) :: :ok | {:error, :product_not_ready | :stale_epoch}
  def validate(epoch, opts \\ [])

  def validate(%{barrier_pid: barrier_pid, snapshot_digest: digest} = epoch, opts)
      when map_size(epoch) == 2 and is_pid(barrier_pid) and is_binary(digest) do
    opts = trusted_validation_opts(epoch, opts)

    case Readiness.status(opts) do
      {:ok, %{phase: :ready, barrier_pid: ^barrier_pid, snapshot_digest: ^digest}} -> :ok
      {:ok, %{phase: :ready}} -> {:error, :stale_epoch}
      _ -> {:error, :product_not_ready}
    end
  end

  def validate(_epoch, _opts), do: {:error, :product_not_ready}

  if Mix.env() == :test do
    defp maybe_register_test_epoch(epoch, opts) do
      case Keyword.fetch(opts, :server) do
        {:ok, server} ->
          case GenServer.whereis(server) do
            pid when is_pid(pid) ->
              AllbertAssist.Pack.EffectGuard.TestRegistry.register(epoch, pid)

            nil ->
              :ok
          end

        :error ->
          :ok
      end
    end

    defp trusted_validation_opts(epoch, []) do
      case AllbertAssist.Pack.EffectGuard.TestRegistry.server(epoch) do
        {:ok, server} -> [server: server]
        :error -> []
      end
    end

    defp trusted_validation_opts(_epoch, opts), do: opts
  else
    defp maybe_register_test_epoch(_epoch, _opts), do: :ok
    defp trusted_validation_opts(_epoch, opts), do: opts
  end
end
