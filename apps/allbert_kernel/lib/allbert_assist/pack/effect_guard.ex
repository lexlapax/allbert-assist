defmodule AllbertAssist.Pack.EffectGuard do
  @moduledoc "Liveness guard for public and steady-state Pack effect boundaries."

  alias AllbertAssist.Pack.EffectGuard.TestRegistry
  alias AllbertAssist.Pack.Readiness

  @type epoch :: %{barrier_pid: pid(), snapshot_digest: String.t()}

  @spec admit_ready(keyword()) :: {:ok, epoch()} | {:error, :product_not_ready}
  def admit_ready(opts \\ []) do
    case Readiness.status(opts) do
      {:ok, %{phase: :ready, barrier_pid: pid, snapshot_digest: digest}}
      when is_pid(pid) and is_binary(digest) ->
        epoch = %{barrier_pid: pid, snapshot_digest: digest}

        admitted_epoch(epoch, opts)

      _ ->
        {:error, :product_not_ready}
    end
  end

  @doc """
  Read and validate the readiness epoch an opts list carries.

  One place instead of sixty-five hand-rolled `Keyword.fetch` clauses. Those
  clauses had drifted into two conventions for the same datum -- some callers
  put the raw epoch under `:allbert_pack_epoch`, others wrapped it in a map
  under `:effect_context` -- and a caller that satisfied one convention while
  its callee read the other validated `nil` and failed closed. That is how the
  fan-out recovery path came to hold Budget v1 children permanently: the epoch
  was present, under the key the callee did not read.

  `:allbert_pack_epoch` is the single convention. Callers hand the raw epoch;
  this returns it validated or explains why not.
  """
  @spec carried_epoch(keyword()) :: {:ok, epoch()} | {:error, :product_not_ready | :stale_epoch}
  def carried_epoch(opts) when is_list(opts) do
    with {:ok, epoch} <- fetch_carried_epoch(opts),
         :ok <- validate(epoch) do
      {:ok, epoch}
    end
  end

  def carried_epoch(_opts), do: {:error, :product_not_ready}

  defp fetch_carried_epoch(opts) do
    case Keyword.fetch(opts, :allbert_pack_epoch) do
      {:ok, epoch} when is_map(epoch) -> {:ok, epoch}
      _ -> {:error, :product_not_ready}
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

  # The admission result is decided inside the env branch rather than by a case
  # at the call site. Outside :test the registration is unconditionally :ok, so
  # a call-site `{:error, _} ->` clause is unreachable and dev/prod builds warn
  # that it can never match — while the same clause is genuinely reachable under
  # :test. Deciding here keeps both environments warning-free without weakening
  # the test-only failure path.
  if Mix.env() == :test do
    defp admitted_epoch(epoch, opts) do
      case maybe_register_test_epoch(epoch, opts) do
        :ok -> {:ok, epoch}
        {:error, _reason} -> {:error, :product_not_ready}
      end
    end

    defp maybe_register_test_epoch(epoch, opts) do
      case Keyword.fetch(opts, :server) do
        {:ok, server} ->
          case GenServer.whereis(server) do
            pid when is_pid(pid) ->
              TestRegistry.register(epoch, pid)

            nil ->
              :ok
          end

        :error ->
          :ok
      end
    end

    defp trusted_validation_opts(epoch, []) do
      case TestRegistry.server(epoch) do
        {:ok, server} -> [server: server]
        :error -> []
      end
    end

    defp trusted_validation_opts(_epoch, opts), do: opts
  else
    defp admitted_epoch(epoch, _opts), do: {:ok, epoch}
    defp trusted_validation_opts(_epoch, opts), do: opts
  end
end
