defmodule AllbertAssist.Search.Presentation do
  @moduledoc """
  Deterministic, transport-neutral presentation of a Search page.

  Search surfaces render this text rather than importing projection or Corpus
  internals. Every hit carries an explicit author, surface, timestamp, message
  source, and canonical thread identity.
  """

  alias AllbertAssist.Maps

  @spec render(map()) :: String.t()
  def render(page) when is_map(page) do
    results = field(page, :results, [])

    [
      heading(results, page),
      result_lines(results),
      page_lines(page)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  def render(_page), do: "Search results unavailable."

  defp heading(results, page) do
    suffix =
      if field(page, :incomplete, false),
        do: " (incomplete: authorization scan budget reached)",
        else: ""

    "Search results: #{length(results)}#{suffix}"
  end

  defp result_lines([]), do: ["No currently authorized matches."]

  defp result_lines(results) do
    results
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {result, index} ->
      [
        "",
        "#{index}. [#{identity_label(result)}]",
        field(result, :snippet, ""),
        "source: conversation:#{field(result, :source_id)} thread:#{field(result, :thread_id)}"
      ]
    end)
  end

  defp page_lines(page) do
    [
      freshness_line(page),
      cursor_line(field(page, :next_cursor))
    ]
  end

  defp identity_label(result) do
    [
      field(result, :author, :unknown),
      field(result, :surface, :unknown),
      timestamp(field(result, :timestamp)),
      "trust=#{field(result, :trust, :unknown)}"
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(" · ")
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_value), do: "timestamp-unknown"

  defp freshness_line(page) do
    case field(page, :freshness_ms) do
      value when is_integer(value) and value >= 0 -> "Index freshness: #{value} ms"
      _other -> nil
    end
  end

  defp cursor_line(value) when is_binary(value) and value != "", do: "Next cursor: #{value}"
  defp cursor_line(_value), do: nil

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
