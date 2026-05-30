defmodule AllbertAssist.Tools.Finder do
  @moduledoc """
  Orchestrates tool discovery sources and normalizes merged results.
  """

  alias AllbertAssist.Tools.Source.Local
  alias AllbertAssist.Tools.Source.McpRegistry
  alias AllbertAssist.Tools.ToolCandidate

  @default_limit 25
  @max_limit 100

  @doc "Search the local source only."
  @spec find_local(String.t(), map()) :: {:ok, [ToolCandidate.t()]} | {:error, term()}
  def find_local(query, opts \\ %{}) when is_map(opts) do
    Local.search(query, opts)
  end

  @doc "Search enabled discovery sources and merge/dedupe their candidates."
  @spec find(String.t(), map()) :: {:ok, %{candidates: [ToolCandidate.t()], diagnostics: [map()]}}
  def find(query, opts \\ %{}) when is_map(opts) do
    limit = limit(opts)

    source_modules(opts)
    |> Task.async_stream(&search_source(&1, query, opts),
      timeout: source_timeout_ms(opts),
      max_concurrency: source_concurrency(opts),
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], []}, &collect_source_result/2)
    |> then(fn {candidates, diagnostics} ->
      candidates =
        candidates
        |> dedupe()
        |> Enum.sort_by(&rank_key(&1, query))
        |> Enum.take(limit)

      {:ok, %{candidates: candidates, diagnostics: Enum.reverse(diagnostics)}}
    end)
  end

  defp search_source(module, query, opts) do
    source_id = source_id(module)

    case do_search_source(module, query, opts) do
      {:ok, candidates, diagnostics} ->
        {:ok, source_id, candidates, diagnostics}

      {:error, reason} ->
        {:error, source_id, reason}
    end
  rescue
    exception ->
      {:error, source_id(module), {exception.__struct__, Exception.message(exception)}}
  end

  defp do_search_source(module, query, opts) do
    if function_exported?(module, :search_with_diagnostics, 2) do
      case module.search_with_diagnostics(query, opts) do
        {:ok, %{candidates: candidates, diagnostics: diagnostics}} ->
          {:ok, candidates, diagnostics}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case module.search(query, opts) do
        {:ok, candidates} -> {:ok, candidates, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp collect_source_result(
         {:ok, {:ok, _source_id, candidates, source_diagnostics}},
         {all, diagnostics}
       ) do
    diagnostics = Enum.map(source_diagnostics, &normalize_source_diagnostic/1) ++ diagnostics

    {all ++ candidates, diagnostics}
  end

  defp collect_source_result({:ok, {:error, source_id, reason}}, {all, diagnostics}) do
    {all, [diagnostic(source_id, reason) | diagnostics]}
  end

  defp collect_source_result({:exit, reason}, {all, diagnostics}) do
    {all, [diagnostic(:unknown, reason) | diagnostics]}
  end

  defp dedupe(candidates) do
    candidates
    |> Enum.reduce(%{}, fn %ToolCandidate{} = candidate, acc ->
      Map.put_new(acc, dedupe_key(candidate), candidate)
    end)
    |> Map.values()
  end

  defp dedupe_key(%ToolCandidate{} = candidate) do
    {candidate.source, candidate.name |> to_string() |> String.downcase()}
  end

  defp rank_key(%ToolCandidate{} = candidate, query) do
    normalized_query = normalize(query)
    normalized_name = normalize(candidate.name)
    normalized_description = normalize(candidate.description)

    score =
      cond do
        normalized_query == "" -> 50
        normalized_name == normalized_query -> 0
        String.contains?(normalized_name, normalized_query) -> 10
        String.contains?(normalized_description, normalized_query) -> 20
        true -> 40
      end

    {source_family_order(candidate.source), score, normalized_name, candidate.id}
  end

  defp source_family_order(:remote_mcp), do: 1
  defp source_family_order(_source), do: 0

  defp source_modules(opts),
    do: Map.get(opts, :sources, Map.get(opts, "sources", default_sources()))

  defp default_sources, do: [Local, McpRegistry]

  defp source_id(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :source_id, 0) do
      module.source_id()
    else
      module
    end
  end

  defp source_timeout_ms(opts) do
    case Map.get(opts, :source_timeout_ms, Map.get(opts, "source_timeout_ms", 5_000)) do
      value when is_integer(value) and value > 0 -> value
      _value -> 5_000
    end
  end

  defp source_concurrency(opts) do
    opts
    |> source_modules()
    |> length()
    |> max(1)
  end

  defp limit(opts) do
    case Map.get(opts, :limit, Map.get(opts, "limit", @default_limit)) do
      value when is_integer(value) and value > 0 -> min(value, @max_limit)
      _value -> @default_limit
    end
  end

  defp diagnostic(source_id, reason) do
    %{source: source_id, status: :degraded, reason: inspect(reason)}
  end

  defp normalize_source_diagnostic(
         %{source: _source, status: _status, reason: _reason} = diagnostic
       ) do
    diagnostic
  end

  defp normalize_source_diagnostic(diagnostic),
    do: %{source: :unknown, status: :degraded, reason: inspect(diagnostic)}

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end
end
