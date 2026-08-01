defmodule AllbertAssist.Intent.FanoutCountedProtocol do
  @moduledoc """
  Offline Adapter for Allbert's two frozen exact-counted fanout protocols.

  This parser recognizes only the documented counted forms. It verifies the
  declared count against complete, non-empty, distinct task strings and does
  not infer orchestration from punctuation, list shape, or ordinary prose.
  """

  @counted_report ~r/^\s*do\s+(?<count>two|three|four|five|six|seven|eight|\d+)\s+(?:things|tasks)\s*:\s*(?<tasks>.+?)[.!?]\s+work on them in parallel(?:\s+and\s+report back)?[.!?]?\s*$/isu
  @counted_inline ~r/^\s*do\s+these\s+(?<count>two|three|four|five|six|seven|eight|\d+)\s+(?:things|tasks)\s+in parallel\s*:\s*(?<tasks>.+?)\s*$/isu
  @counted_report_prefix ~r/^\s*do\s+(?<count>[^\s:]+)\s+(?:things|tasks)\s*:/iu
  @counted_inline_prefix ~r/^\s*do\s+these\s+(?<count>[^\s:]+)\s+(?:things|tasks)\s+in parallel\s*:/iu

  @type invalid_reason ::
          :invalid_declared_count
          | :declared_count_mismatch
          | :duplicate_tasks
          | :invalid_compiled_plan
          | :incomplete_counted_protocol
  @type parse_result :: {:ok, [String.t()]} | {:invalid, invalid_reason()} | :not_counted

  @spec parse(term()) :: parse_result()
  def parse(text) when is_binary(text) do
    case parse_report(text) do
      nil -> parse_inline_or_invalid(text)
      result -> result
    end
  end

  def parse(_text), do: :not_counted

  defp parse_inline_or_invalid(text) do
    case parse_inline(text) do
      nil ->
        case invalid_prefix(text) do
          nil -> :not_counted
          result -> result
        end

      result ->
        result
    end
  end

  defp parse_report(text) do
    case Regex.named_captures(@counted_report, text) do
      %{"count" => count, "tasks" => tasks} ->
        with {:ok, expected_count} <- parse_count(count) do
          tasks
          |> split_report_tasks(expected_count)
          |> validate_tasks(expected_count)
        else
          _other -> {:invalid, :declared_count_mismatch}
        end

      nil ->
        nil
    end
  end

  defp parse_inline(text) do
    case Regex.named_captures(@counted_inline, text) do
      %{"count" => count, "tasks" => tasks} ->
        with {:ok, expected_count} <- parse_count(count) do
          ~r/\s*;\s*/u
          |> Regex.split(tasks, trim: true)
          |> validate_tasks(expected_count)
        else
          _other -> {:invalid, :declared_count_mismatch}
        end

      nil ->
        nil
    end
  end

  defp invalid_prefix(text) do
    captures =
      Regex.named_captures(@counted_report_prefix, text) ||
        Regex.named_captures(@counted_inline_prefix, text)

    case captures do
      %{"count" => count} ->
        case parse_count(count) do
          {:ok, _count} -> {:invalid, :incomplete_counted_protocol}
          :error -> {:invalid, :invalid_declared_count}
        end

      nil ->
        nil
    end
  end

  defp split_report_tasks(tasks, 2) do
    Regex.split(~r/\s*(?:,\s*)?\band\s*/iu, tasks, trim: true)
  end

  defp split_report_tasks(tasks, _count) do
    tasks
    |> String.split(~r/\s*,\s*/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^and\s+/iu, ""))
  end

  defp validate_tasks(tasks, expected_count) do
    tasks = Enum.map(tasks, &String.trim/1)

    cond do
      length(tasks) != expected_count or Enum.any?(tasks, &(&1 == "")) ->
        {:invalid, :declared_count_mismatch}

      length(Enum.uniq(tasks)) != expected_count ->
        {:invalid, :duplicate_tasks}

      true ->
        {:ok, tasks}
    end
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
end
