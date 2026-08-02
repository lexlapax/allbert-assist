defmodule AllbertAssist.Objectives.Fanout.EndpointAdmission do
  @moduledoc """
  Serializes concurrent fan-out child model calls that share one local endpoint.

  v1.3 M9.b.6 (ADR 0021 A24). This is a pure admission predicate over an already
  resolved endpoint identity, not a scheduler, queue, store, or supervision
  child. It reuses the existing Objectives runs registry with its own key
  namespace and adds no process of its own.

  Two children pointed at one local Ollama endpoint do not get faster by being
  in flight together: they contend for the same weights and the same GPU, and
  the recorded v1.3 qualification showed that contention consuming the whole row
  deadline. Admitting one at a time inside the same plan deadline trades no
  throughput and removes the contention.

  Hosted endpoints keep their existing concurrency: they are separately
  provisioned and their identity is deliberately not admitted here.

  Admission never grants authority. It decides *when* a call may be attempted,
  never whether it is permitted; Registry, Runner, Security Central, and
  confirmations are unchanged.
  """

  require Logger

  @registry AllbertAssist.Objectives.Runs.Registry
  @poll_interval_ms 25

  @typedoc "An opaque local endpoint identity, or nil when serialization does not apply."
  @type endpoint_id :: String.t() | nil

  @doc """
  Run `fun` with exclusive admission for `endpoint_id` until the deadline.

  Returns `fun`'s value on admission. Returns `{:error,
  :fanout_plan_deadline_exhausted}` when the deadline passes before admission,
  which callers already treat as a bounded fan-out failure.

  A nil `endpoint_id` (hosted provider, or an unresolved binding) runs `fun`
  immediately, so this can never become a silent global serialization point.
  """
  @spec with_endpoint(endpoint_id(), integer(), (-> result)) ::
          result | {:error, :fanout_plan_deadline_exhausted}
        when result: term()
  def with_endpoint(endpoint_id, deadline_monotonic_ms, fun)

  def with_endpoint(nil, _deadline_monotonic_ms, fun) when is_function(fun, 0), do: fun.()

  def with_endpoint(endpoint_id, deadline_monotonic_ms, fun)
      when is_binary(endpoint_id) and is_integer(deadline_monotonic_ms) and is_function(fun, 0) do
    case acquire(endpoint_id, deadline_monotonic_ms) do
      :ok ->
        try do
          fun.()
        after
          release(endpoint_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def with_endpoint(_endpoint_id, _deadline_monotonic_ms, fun) when is_function(fun, 0),
    do: fun.()

  @doc "Return the registry key used for one endpoint identity."
  @spec key(String.t()) :: {:fanout_endpoint, String.t()}
  def key(endpoint_id) when is_binary(endpoint_id), do: {:fanout_endpoint, endpoint_id}

  @doc """
  Derive a stable local endpoint identity from a resolved role binding.

  Returns nil for hosted endpoints and for any binding that does not name a
  local endpoint, so those keep existing concurrency.
  """
  @spec endpoint_id(map() | nil) :: endpoint_id()
  def endpoint_id(%{} = binding) do
    with kind when kind in ["local_endpoint", "local"] <- field(binding, "endpoint_kind"),
         endpoint when is_binary(endpoint) and endpoint != "" <-
           field(binding, "effective_endpoint") || field(binding, "configured_endpoint") do
      endpoint
    else
      _hosted_or_unresolved -> nil
    end
  end

  def endpoint_id(_binding), do: nil

  defp field(binding, key) do
    Map.get(binding, key) || Map.get(binding, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(binding, key)
  end

  defp acquire(endpoint_id, deadline_monotonic_ms) do
    case Registry.register(@registry, key(endpoint_id), nil) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        wait(endpoint_id, deadline_monotonic_ms)
    end
  end

  defp wait(endpoint_id, deadline_monotonic_ms) do
    remaining = deadline_monotonic_ms - System.monotonic_time(:millisecond)

    if remaining > @poll_interval_ms do
      Process.sleep(@poll_interval_ms)
      acquire(endpoint_id, deadline_monotonic_ms)
    else
      {:error, :fanout_plan_deadline_exhausted}
    end
  end

  defp release(endpoint_id), do: Registry.unregister(@registry, key(endpoint_id))
end
