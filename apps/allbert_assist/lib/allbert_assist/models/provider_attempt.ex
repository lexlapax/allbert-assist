defmodule AllbertAssist.Models.ProviderAttempt do
  @moduledoc """
  Owner-scoped accounting for physical model-provider request attempts.

  The counter is transient and process-independent so an owner can still read
  the exact admitted-attempt count after a linked provider task exits or is
  brutally stopped. It grants no budget, retry, persistence, or authority.
  """

  @counter_key :allbert_provider_attempt_counter
  @phase_key :allbert_provider_attempt_phase

  @type phase :: :generation | :revision
  @type phased_context :: %{
          required(:allbert_provider_attempt_phase) => phase(),
          optional(term()) => term()
        }
  @type phase_counts :: %{
          total: non_neg_integer(),
          generation: non_neg_integer(),
          revision: non_neg_integer()
        }

  @doc "Attach a fresh transient counter to one bounded provider-call context."
  @spec attach(map()) :: {map(), :counters.counters_ref()}
  def attach(context) when is_map(context) do
    counter = :counters.new(3, [:write_concurrency])
    {Map.put(context, @counter_key, counter), counter}
  end

  @doc """
  Reuse the caller's counter when one is present, otherwise attach a fresh one.

  An owner that already holds a counter can read exact attempt evidence after
  the callee returns, including on failure paths where the callee's own counter
  would be discarded with its error. Callers that supply nothing keep the
  previous attach-a-fresh-counter behavior exactly.
  """
  @spec attach_or_reuse(map()) :: {map(), :counters.counters_ref()}
  def attach_or_reuse(context) when is_map(context) do
    case Map.get(context, @counter_key) do
      nil -> attach(context)
      counter -> {context, counter}
    end
  end

  @doc "Tag a bounded provider context with its generation or revision phase."
  @spec put_phase(map(), phase()) :: phased_context()
  def put_phase(context, phase)
      when is_map(context) and phase in [:generation, :revision],
      do: Map.put(context, @phase_key, phase)

  @doc "Consume one attempt immediately before crossing the physical provider boundary."
  @spec mark(map()) :: :ok | {:error, :invalid_provider_attempt_counter}
  def mark(context) when is_map(context) do
    case Map.get(context, @counter_key) do
      nil ->
        :ok

      counter ->
        try do
          :ok = :counters.add(counter, 1, 1)
          :ok = mark_phase(counter, Map.get(context, @phase_key))
        rescue
          _exception -> {:error, :invalid_provider_attempt_counter}
        catch
          _kind, _reason -> {:error, :invalid_provider_attempt_counter}
        end
    end
  end

  def mark(_context), do: {:error, :invalid_provider_attempt_counter}

  @doc "Read one owner-held transient counter."
  @spec count(:counters.counters_ref()) :: non_neg_integer()
  def count(counter), do: :counters.get(counter, 1)

  @doc "Read content-free physical attempt counts for tagged generation and revision phases."
  @spec phase_counts(:counters.counters_ref()) :: phase_counts()
  def phase_counts(counter) do
    %{
      total: :counters.get(counter, 1),
      generation: :counters.get(counter, 2),
      revision: :counters.get(counter, 3)
    }
  end

  defp mark_phase(counter, :generation), do: :counters.add(counter, 2, 1)
  defp mark_phase(counter, :revision), do: :counters.add(counter, 3, 1)
  defp mark_phase(_counter, _unscoped), do: :ok
end
