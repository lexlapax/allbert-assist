defmodule AllbertAssist.Runtime.DeliveryAcknowledgement do
  @moduledoc """
  Executes one idempotent delivery acknowledgement with bounded database retry.

  This is a plain module because it owns no process state. Callers choose the
  process boundary: short-lived surfaces may call it directly, while attended
  surfaces run it in an unlinked supervised task so receipt persistence cannot
  own their input or rendering process.
  """

  alias AllbertAssist.Database.TransientError

  @default_attempts 4
  @default_base_delay_ms 25
  @default_max_delay_ms 200

  @doc "Run an idempotent acknowledgement, retrying only known transient database failures."
  @spec run((-> term()), keyword()) :: term()
  def run(acknowledge_fun, opts \\ []) when is_function(acknowledge_fun, 0) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)
    base_delay_ms = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay_ms = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    delay_fun = Keyword.get(opts, :delay_fun, &Process.sleep/1)

    do_run(acknowledge_fun, 1, attempts, base_delay_ms, max_delay_ms, delay_fun)
  end

  defp do_run(acknowledge_fun, attempt, attempts, base_delay_ms, max_delay_ms, delay_fun) do
    case safely_attempt(acknowledge_fun) do
      {:retry, _reason} when attempt < attempts ->
        delay_fun.(retry_delay(attempt, base_delay_ms, max_delay_ms))
        do_run(acknowledge_fun, attempt + 1, attempts, base_delay_ms, max_delay_ms, delay_fun)

      {:retry, reason} ->
        {:error, {:transient_database, TransientError.summary(reason)}}

      result ->
        result
    end
  end

  defp safely_attempt(acknowledge_fun) do
    case acknowledge_fun.() do
      {:error, {:transient_database, _summary} = reason} ->
        {:retry, reason}

      {:error, reason} = error ->
        if TransientError.transient?(reason), do: {:retry, reason}, else: error

      result ->
        result
    end
  rescue
    exception ->
      if TransientError.transient?(exception) do
        {:retry, exception}
      else
        reraise exception, __STACKTRACE__
      end
  catch
    :exit, reason ->
      if TransientError.transient?(reason), do: {:retry, reason}, else: exit(reason)

    kind, reason ->
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp retry_delay(attempt, base_delay_ms, max_delay_ms) do
    min(base_delay_ms * Integer.pow(2, attempt - 1), max_delay_ms)
  end
end
