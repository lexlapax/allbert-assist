defmodule AllbertAssist.Pack.ProductBootstrap do
  @moduledoc """
  Composition-owned embedded product bootstrap for runtime-bearing CLI entries.

  It starts the composition application only after ProductCLI has established
  that attaching to an existing daemon was impossible. Success is an exact
  current Pack epoch, never merely an application-start result.
  """

  alias AllbertAssist.Pack.Readiness

  @outer_deadline_ms 45_000
  @readiness_deadline_ms 30_000
  @status_timeout_ms 5_000
  @poll_ms 50

  @type epoch :: %{barrier_pid: pid(), snapshot_digest: String.t()}
  @type diagnostic ::
          :application_start_failed | :readiness_failed | :readiness_deadline | :readiness_lost

  @doc "Start composition if necessary and return a freshly checked ready Pack epoch."
  @spec ensure_ready(keyword()) :: {:ok, epoch()} | {:error, diagnostic()}
  def ensure_ready(opts \\ []) when is_list(opts) do
    seams = %{
      application_starter: &Application.ensure_all_started/1,
      application_stopper: &Application.stop/1,
      readiness_await: &await_ready/1,
      readiness_status: &ready_status/1,
      monotonic_ms: &monotonic_ms/0
    }

    ensure_ready_with(opts, seams)
  end

  if Mix.env() == :test do
    @doc false
    def ensure_ready_for_test(opts) do
      seams =
        %{
          application_starter: &Application.ensure_all_started/1,
          application_stopper: &Application.stop/1,
          readiness_await: &await_ready/1,
          readiness_status: &ready_status/1,
          monotonic_ms: &monotonic_ms/0
        }
        |> Map.merge(Map.new(opts))

      ensure_ready_with(opts, seams)
    end
  end

  defp ensure_ready_with(_opts, seams) do
    deadline = seams.monotonic_ms.() + @outer_deadline_ms

    case seams.application_starter.(:allbert_composition) do
      {:ok, started} when is_list(started) ->
        finish_start(started, deadline, seams)

      {:error, _reason} ->
        {:error, :application_start_failed}

      _other ->
        {:error, :application_start_failed}
    end
  end

  defp finish_start(started, deadline, seams) do
    result =
      with :ok <- within_deadline(deadline, seams),
           {:ok, _epoch} <- seams.readiness_await.(readiness_deadline(deadline, seams)),
           :ok <- within_deadline(deadline, seams) do
        final_ready_status(deadline, seams)
      else
        {:error, :deadline} -> {:error, :readiness_deadline}
        {:error, _reason} -> {:error, :readiness_failed}
        _other -> {:error, :readiness_failed}
      end

    case result do
      {:ok, _epoch} = success ->
        success

      {:error, _diagnostic} = failure ->
        stop_new_applications(started, seams.application_stopper)
        failure
    end
  end

  defp final_ready_status(deadline, seams) do
    with {:ok, status} <- seams.readiness_status.(remaining_timeout(deadline, seams)),
         {:ok, epoch} <- epoch_from_status(status) do
      {:ok, epoch}
    else
      _other -> {:error, :readiness_lost}
    end
  end

  defp await_ready(deadline) do
    case Readiness.status(timeout: min(@status_timeout_ms, remaining_ms(deadline))) do
      {:ok, %{phase: :ready} = status} -> epoch_from_status(status)
      {:ok, _status} -> await_next_ready_status(deadline)
      {:error, :unavailable} -> await_next_ready_status(deadline)
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp await_next_ready_status(deadline) do
    if remaining_ms(deadline) <= 0 do
      {:error, :deadline}
    else
      Process.sleep(min(@poll_ms, remaining_ms(deadline)))
      await_ready(deadline)
    end
  end

  defp ready_status(timeout) do
    case Readiness.status(timeout: min(@status_timeout_ms, timeout)) do
      {:ok, %{phase: :ready} = status} -> epoch_from_status(status)
      {:ok, _status} -> {:error, :not_ready}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp epoch_from_status(%{barrier_pid: pid, snapshot_digest: digest})
       when is_pid(pid) and is_binary(digest),
       do: {:ok, %{barrier_pid: pid, snapshot_digest: digest}}

  defp epoch_from_status(_status), do: {:error, :not_ready}

  defp readiness_deadline(deadline, seams) do
    min(deadline, seams.monotonic_ms.() + @readiness_deadline_ms)
  end

  defp remaining_timeout(deadline, seams),
    do: min(@status_timeout_ms, max(deadline - seams.monotonic_ms.(), 0))

  defp within_deadline(deadline, seams),
    do: if(seams.monotonic_ms.() < deadline, do: :ok, else: {:error, :deadline})

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp remaining_ms(deadline), do: max(deadline - monotonic_ms(), 0)

  defp stop_new_applications(started, stopper) do
    Enum.each(Enum.reverse(started), fn application ->
      _ = stopper.(application)
    end)
  end
end
