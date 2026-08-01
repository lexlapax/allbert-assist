defmodule AllbertAssist.Intent.Decomposer do
  @moduledoc """
  Compatibility Interface for the frozen exact-counted fanout protocols.

  The two counted protocols stay deterministic and offline so documented
  automation and operator recovery do not depend on a model. Broader planning
  belongs to the central conversational planning path; this module deliberately
  fails every other shape closed as a single turn. A parsed protocol remains
  advisory and grants no action authority.
  """

  alias AllbertAssist.Intent.{FanoutCountedProtocol, FanoutPlan}

  @steering_only ~r/^\s*(status|progress|cancel|stop|pause|resume|retry|skip)(?:\s|$)/iu

  @type result ::
          {:fanout, [String.t()]}
          | {:clarify, map()}
          | {:invalid_counted, FanoutCountedProtocol.invalid_reason()}
          | :single

  @spec propose(String.t(), map() | keyword()) :: result()
  def propose(text, context \\ %{})

  def propose(text, context) when is_binary(text) do
    context = normalize_context(context)

    if ineligible?(text, context) do
      :single
    else
      case FanoutCountedProtocol.parse(text) do
        {:ok, tasks} -> normalize_proposal(text, tasks, bounded_max(context))
        {:invalid, reason} -> {:invalid_counted, reason}
        :not_counted -> :single
      end
    end
  end

  def propose(_text, _context), do: :single

  defp ineligible?(text, context) do
    trimmed = String.trim(text)

    trimmed == "" or String.starts_with?(trimmed, "/") or
      Map.get(context, :nested_fanout?, false) or Map.get(context, :steering_turn?, false) or
      (Map.get(context, :active_fanout?, false) and Regex.match?(@steering_only, trimmed))
  end

  defp normalize_proposal(original_request, tasks, max) do
    case FanoutPlan.compile_counted_admission(original_request, tasks, max_children: max) do
      {:ok, _plan} ->
        {:fanout, tasks}

      {:clarify, clarification} ->
        {:clarify, clarification}

      {:error, _reason} ->
        {:invalid_counted, :invalid_compiled_plan}
    end
  end

  defp bounded_max(context) do
    case Map.get(context, :max_children_per_fanout, 8) do
      value when is_integer(value) -> value |> max(2) |> min(16)
      _value -> 8
    end
  end

  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(_context), do: %{}
end
