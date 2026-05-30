defmodule AllbertAssist.Tools.Source.McpRegistry do
  @moduledoc """
  Remote MCP registry discovery source.

  The source returns inert `:remote_mcp` candidates only. It also persists the
  candidate and its evaluation metadata so later connect flows can require an
  explicit operator confirmation against a stable baseline.
  """

  @behaviour AllbertAssist.Tools.SourcePort

  alias AllbertAssist.Mcp.Registry.Official
  alias AllbertAssist.Mcp.Registry.PulseMcp
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.ToolCandidate

  @default_limit 25
  @max_limit 100

  @impl true
  def source_id, do: :mcp_registry

  @impl true
  def search(query, opts \\ %{}) do
    with {:ok, %{candidates: candidates}} <- search_with_diagnostics(query, opts) do
      {:ok, candidates}
    end
  end

  @doc "Search enabled registry providers and return candidates plus provider diagnostics."
  def search_with_diagnostics(query, opts \\ %{}) when is_map(opts) do
    if discovery_enabled?(opts) do
      {provider_specs, diagnostics} = provider_specs(opts)

      provider_specs
      |> Task.async_stream(&search_provider(&1, query, opts),
        timeout: source_timeout_ms(opts),
        max_concurrency: max(length(provider_specs), 1),
        on_timeout: :kill_task
      )
      |> Enum.reduce({[], diagnostics}, &collect_provider_result(&1, &2, opts))
      |> then(fn {candidates, diagnostics} ->
        candidates =
          candidates
          |> Enum.sort_by(&rank_key(&1, query))
          |> Enum.take(limit(opts))

        {:ok, %{candidates: candidates, diagnostics: Enum.reverse(diagnostics)}}
      end)
    else
      {:ok, %{candidates: [], diagnostics: []}}
    end
  end

  defp search_provider({provider, provider_opts}, query, opts) do
    case provider.search(query, Map.merge(provider_opts, provider_runtime_opts(opts))) do
      {:ok, results} -> {:ok, provider.provider_id(), results}
      {:error, reason} -> {:error, provider.provider_id(), reason}
    end
  rescue
    exception ->
      {:error, provider.provider_id(), {exception.__struct__, Exception.message(exception)}}
  end

  defp collect_provider_result(
         {:ok, {:ok, provider_id, results}},
         {candidates, diagnostics},
         opts
       ) do
    Enum.reduce(results, {candidates, diagnostics}, fn result, {candidate_acc, diagnostic_acc} ->
      case candidate_from_result(provider_id, result) do
        {:ok, candidate} ->
          diagnostics = persist_discovery(candidate, result, opts, diagnostic_acc)
          {[candidate | candidate_acc], diagnostics}

        {:error, reason} ->
          {candidate_acc, [diagnostic(provider_id, :skipped, reason) | diagnostic_acc]}
      end
    end)
  end

  defp collect_provider_result(
         {:ok, {:error, provider_id, reason}},
         {candidates, diagnostics},
         _opts
       ) do
    {candidates, [diagnostic(provider_id, :degraded, reason) | diagnostics]}
  end

  defp collect_provider_result({:exit, reason}, {candidates, diagnostics}, _opts) do
    {candidates, [diagnostic(:unknown, :degraded, reason) | diagnostics]}
  end

  defp candidate_from_result(provider_id, result) when is_map(result) do
    ToolCandidate.normalize(%{
      id: candidate_id(provider_id, result),
      name: string(result, :name) || string(result, :remote_server_id),
      description: string(result, :description) || "",
      source: :remote_mcp,
      provenance: %{
        provider: provider_id,
        registry: "mcp_registry",
        remote_server_id: string(result, :remote_server_id),
        manifest_url: string(result, :manifest_url),
        repository_url: string(result, :repository_url),
        metadata_authority: "descriptive_metadata_only"
      },
      signals:
        Map.merge(provider_signals(result), %{
          kind: :mcp_registry_server,
          server_url: string(result, :server_url),
          version: string(result, :version),
          updated_at: string(result, :updated_at),
          packages: Map.get(result, :packages, Map.get(result, "packages", [])),
          transport_kinds:
            Map.get(result, :transport_kinds, Map.get(result, "transport_kinds", []))
        })
    })
  end

  defp candidate_from_result(_provider_id, result),
    do: {:error, {:invalid_registry_result, result}}

  defp persist_discovery(candidate, result, opts, diagnostics) do
    if Map.get(opts, :persist?, Map.get(opts, "persist?", true)) do
      do_persist_discovery(candidate, result, opts, diagnostics)
    else
      diagnostics
    end
  end

  defp do_persist_discovery(candidate, result, opts, diagnostics) do
    manifest = Map.get(result, :manifest, Map.get(result, "manifest", %{}))

    with {:ok, _record} <- Discovery.upsert_candidate(candidate, %{registry_record: manifest}),
         {:ok, report} <-
           Discovery.evaluate_server(manifest, %{
             candidate_id: candidate.id,
             provider: candidate.provenance.provider,
             remote_server_id: candidate.provenance.remote_server_id,
             context: Map.get(opts, :context, Map.get(opts, "context", %{})),
             probe?: Map.get(opts, :probe?, Map.get(opts, "probe?", false))
           }),
         {:ok, _report_record} <- Discovery.upsert_evaluation_report(candidate.id, report),
         {:ok, _suggestion} <-
           Discovery.upsert_suggestion(
             candidate.id,
             ToolCandidate.to_map(candidate),
             Discovery.evaluation_to_map(report)
           ),
         {:ok, _baseline} <- Discovery.upsert_baseline_trust_record(candidate.id, report) do
      diagnostics
    else
      {:error, reason} ->
        [diagnostic(candidate.provenance.provider, :persistence_degraded, reason) | diagnostics]
    end
  end

  defp provider_specs(opts) do
    forced = Map.get(opts, :providers, Map.get(opts, "providers"))

    if is_list(forced) do
      {Enum.map(forced, &forced_provider_spec(&1, opts)), []}
    else
      default_provider_specs(opts)
    end
  end

  defp forced_provider_spec(provider, opts) do
    module =
      case provider do
        :official -> Official
        "official" -> Official
        :pulsemcp -> PulseMcp
        "pulsemcp" -> PulseMcp
        module when is_atom(module) -> module
      end

    {module, provider_opts(module, opts)}
  end

  defp default_provider_specs(opts) do
    {official_specs(opts), []}
    |> maybe_add_pulsemcp(opts)
  end

  defp official_specs(opts) do
    if setting("mcp.discovery.sources.official.enabled", true) do
      [{Official, provider_opts(Official, opts)}]
    else
      []
    end
  end

  defp maybe_add_pulsemcp({providers, diagnostics}, opts) do
    if setting("mcp.discovery.sources.pulsemcp.enabled", false) do
      case PulseMcp.configured_status() do
        :ok ->
          {[{PulseMcp, provider_opts(PulseMcp, opts)} | providers], diagnostics}

        status ->
          {providers, [diagnostic(:pulsemcp, :skipped, status) | diagnostics]}
      end
    else
      {providers, diagnostics}
    end
  end

  defp provider_opts(provider, opts) do
    provider_key =
      provider
      |> provider_id()
      |> Atom.to_string()

    opts
    |> Map.get(:provider_opts, Map.get(opts, "provider_opts", %{}))
    |> case do
      provider_opts when is_map(provider_opts) ->
        Map.get(provider_opts, provider_id(provider), Map.get(provider_opts, provider_key, %{}))

      _other ->
        %{}
    end
  end

  defp provider_runtime_opts(opts) do
    %{
      context: Map.get(opts, :context, Map.get(opts, "context", %{})),
      limit: limit(opts),
      max_response_bytes:
        Map.get(opts, :max_response_bytes, Map.get(opts, "max_response_bytes", 512_000)),
      timeout_ms: Map.get(opts, :timeout_ms, Map.get(opts, "timeout_ms", 5_000))
    }
  end

  defp provider_id(Official), do: :official
  defp provider_id(PulseMcp), do: :pulsemcp
  defp provider_id(module) when is_atom(module), do: module.provider_id()

  defp discovery_enabled?(opts) do
    Map.get(opts, :enabled?, Map.get(opts, "enabled?", setting("mcp.discovery.enabled", false))) ==
      true
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp limit(opts) do
    case Map.get(opts, :limit, Map.get(opts, "limit", @default_limit)) do
      value when is_integer(value) and value > 0 -> min(value, @max_limit)
      _value -> @default_limit
    end
  end

  defp source_timeout_ms(opts) do
    case Map.get(opts, :source_timeout_ms, Map.get(opts, "source_timeout_ms", 5_000)) do
      value when is_integer(value) and value > 0 -> value
      _value -> 5_000
    end
  end

  defp rank_key(%ToolCandidate{} = candidate, query) do
    normalized_query = normalize(query)
    normalized_name = normalize(candidate.name)
    normalized_description = normalize(candidate.description)
    provider_order = if candidate.provenance.provider == :official, do: 0, else: 1

    match_score =
      cond do
        normalized_query == "" -> 50
        normalized_name == normalized_query -> 0
        String.contains?(normalized_name, normalized_query) -> 10
        String.contains?(normalized_description, normalized_query) -> 20
        true -> 40
      end

    popularity =
      -1 *
        max(
          integer_signal(candidate, :github_stars),
          integer_signal(candidate, :package_download_count)
        )

    {match_score, provider_order, popularity, normalized_name}
  end

  defp integer_signal(candidate, key) do
    case Map.get(candidate.signals, key, Map.get(candidate.signals, Atom.to_string(key), 0)) do
      value when is_integer(value) -> value
      _value -> 0
    end
  end

  defp provider_signals(result) do
    result
    |> Map.get(:signals, Map.get(result, "signals", %{}))
    |> case do
      signals when is_map(signals) -> signals
      _other -> %{}
    end
  end

  defp candidate_id(provider_id, result) do
    remote_server_id = string(result, :remote_server_id) || string(result, :name) || "server"

    slug =
      remote_server_id
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "server"
        value -> value
      end

    digest =
      :crypto.hash(:sha256, "#{provider_id}:#{remote_server_id}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "remote_mcp:#{provider_id}:#{slug}:#{digest}"
  end

  defp diagnostic(source, status, reason) do
    %{source: source, status: status, reason: inspect(reason)}
  end

  defp string(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
    |> case do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end
end
