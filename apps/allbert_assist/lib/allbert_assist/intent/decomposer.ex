defmodule AllbertAssist.Intent.Decomposer do
  @moduledoc """
  Advisory Stage-0 decomposition for eligible new Runtime turns.

  Cheap deterministic guards run first. A model is consulted only for text
  with plausible multi-task shape, and every result is bounded before it can
  frame durable objectives. Decomposition grants no action authority.
  """

  alias AllbertAssist.Intent.Decomposer.ReqLLMProposer

  @explicit_single ~r/\b(as (?:a |one )?single task|as one task|together|do(?:n't| not) split|without splitting|one combined task)\b/iu
  @parallel_signal ~r/\b(in parallel|simultaneously|separately|independently|at the same time|also|and then|then)\b/iu
  @steering_only ~r/^\s*(status|progress|cancel|stop|pause|resume|retry|skip)(?:\s|$)/iu
  @numbered_line ~r/^\s*(?:\d+[.)]|[-*])\s+(.+?)\s*$/u
  @counted_parallel ~r/^\s*do\s+(?<count>two|three|four|five|six|seven|eight|\d+)\s+(?:things|tasks)\s*:\s*(?<tasks>.+?)[.!?]\s+work on them in parallel(?:\s+and\s+report back)?[.!?]?\s*$/isu

  @type result :: {:fanout, [String.t()]} | {:clarify, map()} | :single

  @spec propose(String.t(), map() | keyword()) :: result()
  def propose(text, context \\ %{})

  def propose(text, context) when is_binary(text) do
    context = normalize_context(context)
    max_children = bounded_max(Map.get(context, :max_children_per_fanout, 8))

    cond do
      ineligible?(text, context) ->
        :single

      tasks = deterministic_tasks(text) ->
        normalize_proposal(tasks, max_children)

      plausible_multi?(text) ->
        text
        |> model_proposal(context)
        |> normalize_proposal(max_children)

      true ->
        :single
    end
  end

  def propose(_text, _context), do: :single

  @doc "Cheap guard used by Runtime to avoid a model call on ordinary single turns."
  @spec plausible_multi?(String.t()) :: boolean()
  def plausible_multi?(text) when is_binary(text) do
    Regex.match?(@parallel_signal, text) or
      length(Regex.scan(~r/(?:^|\n)\s*(?:\d+[.)]|[-*])\s+/u, text)) >= 2 or
      String.contains?(text, ";") or
      Regex.match?(~r/,[^,]+,\s*(?:and|also)\s+[^,]+$/iu, String.trim(text))
  end

  defp ineligible?(text, context) do
    trimmed = String.trim(text)

    trimmed == "" or String.starts_with?(trimmed, "/") or
      Regex.match?(@explicit_single, trimmed) or Map.get(context, :nested_fanout?, false) or
      Map.get(context, :steering_turn?, false) or
      (Map.get(context, :active_fanout?, false) and Regex.match?(@steering_only, trimmed))
  end

  defp deterministic_tasks(text) do
    counted = counted_parallel_tasks(text)

    numbered =
      text
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(@numbered_line, line, capture: :all_but_first) do
          [task] -> [task]
          _ -> []
        end
      end)

    cond do
      counted ->
        counted

      length(numbered) >= 2 ->
        numbered

      String.contains?(text, ";") ->
        split_on(text, ~r/\s*;\s*/u)

      Regex.match?(~r/\b(?:and then|then)\b/iu, text) ->
        split_on(text, ~r/\s+\b(?:and then|then)\b\s+/iu)

      Regex.match?(~r/\b(?:in parallel|separately|independently)\b/iu, text) ->
        split_parallel_clause(text)

      true ->
        nil
    end
  end

  defp counted_parallel_tasks(text) do
    with %{"count" => count, "tasks" => tasks} <- Regex.named_captures(@counted_parallel, text),
         {:ok, expected_count} <- parse_count(count),
         parsed when length(parsed) == expected_count <-
           split_counted_tasks(tasks, expected_count) do
      parsed
    else
      _other -> nil
    end
  end

  defp split_counted_tasks(tasks, 2) do
    split_on(tasks, ~r/\s*(?:,\s*)?\band\b\s*/iu) || []
  end

  defp split_counted_tasks(tasks, _count) do
    tasks
    |> String.split(~r/\s*,\s*/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^and\s+/iu, ""))
  end

  defp parse_count(count) do
    case String.downcase(count) do
      "two" -> {:ok, 2}
      "three" -> {:ok, 3}
      "four" -> {:ok, 4}
      "five" -> {:ok, 5}
      "six" -> {:ok, 6}
      "seven" -> {:ok, 7}
      "eight" -> {:ok, 8}
      digits -> parse_numeric_count(digits)
    end
  end

  defp parse_numeric_count(digits) do
    case Integer.parse(digits) do
      {count, ""} when count >= 2 -> {:ok, count}
      _other -> :error
    end
  end

  defp split_parallel_clause(text) do
    text
    |> String.replace(~r/\b(?:in parallel|separately|independently)\b[:,]?/iu, "")
    |> split_on(~r/\s+(?:and|also)\s+/iu)
  end

  defp split_on(text, pattern) do
    tasks = Regex.split(pattern, text, trim: true)
    if length(tasks) >= 2, do: tasks, else: nil
  end

  defp model_proposal(text, context) do
    proposer = Map.get(context, :model_proposer, ReqLLMProposer)

    case proposer.propose(text, context) do
      {:ok, tasks} when is_list(tasks) -> tasks
      _ -> nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp normalize_proposal(nil, _max), do: :single

  defp normalize_proposal(tasks, max) do
    tasks =
      tasks
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      length(tasks) < 2 ->
        :single

      length(tasks) > max ->
        {:clarify, %{task_count: length(tasks), max_children: max, tasks: tasks}}

      true ->
        {:fanout, tasks}
    end
  end

  defp bounded_max(value) when is_integer(value), do: value |> max(2) |> min(16)
  defp bounded_max(_value), do: 8
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(_context), do: %{}
end
