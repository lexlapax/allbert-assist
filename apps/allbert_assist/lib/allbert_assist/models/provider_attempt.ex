defmodule AllbertAssist.Models.ProviderAttempt do
  @moduledoc """
  Owner-scoped accounting for physical model-provider request attempts.

  The counter is transient and process-independent so an owner can still read
  the exact admitted-attempt count after a linked provider task exits or is
  brutally stopped. It grants no budget, retry, persistence, or authority.
  """

  @counter_key :allbert_provider_attempt_counter

  @doc "Attach a fresh transient counter to one bounded provider-call context."
  @spec attach(map()) :: {map(), reference()}
  def attach(context) when is_map(context) do
    counter = :counters.new(1, [:write_concurrency])
    {Map.put(context, @counter_key, counter), counter}
  end

  @doc "Consume one attempt immediately before crossing the physical provider boundary."
  @spec mark(map()) :: :ok | {:error, :invalid_provider_attempt_counter}
  def mark(context) when is_map(context) do
    case Map.get(context, @counter_key) do
      nil ->
        :ok

      counter ->
        try do
          :ok = :counters.add(counter, 1, 1)
        rescue
          _exception -> {:error, :invalid_provider_attempt_counter}
        catch
          _kind, _reason -> {:error, :invalid_provider_attempt_counter}
        end
    end
  end

  def mark(_context), do: {:error, :invalid_provider_attempt_counter}

  @doc "Read one owner-held transient counter."
  @spec count(reference()) :: non_neg_integer()
  def count(counter), do: :counters.get(counter, 1)
end
