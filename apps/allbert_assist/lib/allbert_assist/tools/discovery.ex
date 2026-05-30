defmodule AllbertAssist.Tools.Discovery do
  @moduledoc """
  Durable store and evaluator for discovered MCP tool candidates.

  Records in this context are descriptive. They never grant tool access; remote
  MCP candidates stay inert until the separate server-connect gate persists a
  configured server.
  """

  import Ecto.Query

  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Repo
  alias AllbertAssist.Tools.Discovery.BaselineTrustRecord
  alias AllbertAssist.Tools.Discovery.CandidateRecord
  alias AllbertAssist.Tools.Discovery.EvaluationReport
  alias AllbertAssist.Tools.Discovery.Suggestion
  alias AllbertAssist.Tools.ToolCandidate

  @dangerous_patterns [
    {~r/\brm\s+-rf\b/i, "destructive_recursive_remove"},
    {~r/\bcurl\b.*\|\s*(sh|bash)\b/i, "remote_script_pipe"},
    {~r/\bwget\b.*\|\s*(sh|bash)\b/i, "remote_script_pipe"},
    {~r/\bsudo\b/i, "privileged_command"},
    {~r/\bchmod\s+777\b/i, "world_writable_permission"},
    {~r/\bpowershell\b.*-enc/i, "encoded_powershell"}
  ]

  @command_path_tokens ~w(command commands args script scripts install postinstall run)

  @doc "Insert or refresh a discovered candidate record."
  @spec upsert_candidate(ToolCandidate.t(), map()) ::
          {:ok, CandidateRecord.t()} | {:error, term()}
  def upsert_candidate(%ToolCandidate{} = candidate, attrs \\ %{}) when is_map(attrs) do
    now = DateTime.utc_now()

    record_attrs =
      candidate
      |> candidate_attrs(attrs, now)
      |> json_safe_attrs([:provenance, :signals, :registry_record])

    case Repo.get(CandidateRecord, candidate.id) do
      nil ->
        %CandidateRecord{}
        |> CandidateRecord.changeset(record_attrs)
        |> Repo.insert()

      %CandidateRecord{} = record ->
        record
        |> CandidateRecord.changeset(Map.delete(record_attrs, :first_seen_at))
        |> Repo.update()
    end
  end

  @doc "Fetch a discovered candidate record by id."
  @spec get_candidate(String.t()) :: {:ok, CandidateRecord.t()} | {:error, :not_found}
  def get_candidate(candidate_id) when is_binary(candidate_id) do
    case Repo.get(CandidateRecord, candidate_id) do
      %CandidateRecord{} = record -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  @doc "List persisted candidates with light filtering."
  @spec list_candidates(keyword()) :: {:ok, [CandidateRecord.t()]}
  def list_candidates(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 25)

    CandidateRecord
    |> maybe_where(:source, Keyword.get(opts, :source))
    |> maybe_where(:provider, Keyword.get(opts, :provider))
    |> order_by([candidate], desc: candidate.last_seen_at, asc: candidate.name)
    |> limit(^limit)
    |> Repo.all()
    |> then(&{:ok, &1})
  end

  @doc "Evaluate an MCP server manifest or registry record without granting access."
  @spec evaluate_server(map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate_server(manifest, opts \\ %{})

  def evaluate_server(manifest, opts) when is_map(manifest) do
    provider = string_opt(opts, :provider) || provider_from_manifest(manifest)
    remote_server_id = string_opt(opts, :remote_server_id) || server_id(manifest)
    candidate_id = string_opt(opts, :candidate_id)
    health = health_probe(manifest, opts)
    tool_definition_hash = stable_hash(tool_definition_basis(manifest))
    dangerous_command_flags = dangerous_command_flags(manifest)
    provenance_level = provenance_level(provider, manifest)

    {:ok,
     %{
       id: evaluation_id(candidate_id, provider, remote_server_id, tool_definition_hash),
       candidate_id: candidate_id,
       provider: provider,
       remote_server_id: remote_server_id,
       provenance_level: provenance_level,
       dangerous_command_flags: dangerous_command_flags,
       health_status: health.status,
       health_diagnostics: health.diagnostics,
       tool_definition_hash: tool_definition_hash,
       metadata_authority: "descriptive_metadata_only",
       manifest: manifest,
       diagnostics: %{
         "dangerous_command_flag_count" => length(dangerous_command_flags),
         "metadata_only?" => true
       },
       evaluated_at: DateTime.utc_now()
     }}
  end

  def evaluate_server(_manifest, _opts), do: {:error, :invalid_manifest}

  @doc "Compute the stable hash for the tool definitions exposed by a server."
  @spec tool_list_hash([map()]) :: String.t()
  def tool_list_hash(tools) when is_list(tools) do
    %{"tools" => Enum.map(tools, &tool_definition/1)}
    |> stable_hash()
  end

  def tool_list_hash(_tools), do: tool_list_hash([])

  @doc "Insert or refresh the latest evaluation report for one candidate."
  @spec upsert_evaluation_report(String.t(), map()) ::
          {:ok, EvaluationReport.t()} | {:error, term()}
  def upsert_evaluation_report(candidate_id, report)
      when is_binary(candidate_id) and is_map(report) do
    attrs =
      report
      |> Map.put(:id, "eval:#{candidate_id}")
      |> Map.put(:candidate_id, candidate_id)
      |> Map.update(:dangerous_command_flags, %{"flags" => []}, fn
        flags when is_list(flags) -> %{"flags" => flags}
        flags when is_map(flags) -> flags
        _other -> %{"flags" => []}
      end)
      |> json_safe_attrs([:dangerous_command_flags, :health_diagnostics, :manifest, :diagnostics])

    case Repo.get(EvaluationReport, "eval:#{candidate_id}") do
      nil ->
        %EvaluationReport{}
        |> EvaluationReport.changeset(attrs)
        |> Repo.insert()

      %EvaluationReport{} = record ->
        record
        |> EvaluationReport.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Return a public action-safe map from an evaluation report map or record."
  def evaluation_to_map(%EvaluationReport{} = report) do
    %{
      id: report.id,
      candidate_id: report.candidate_id,
      provider: report.provider,
      remote_server_id: report.remote_server_id,
      provenance_level: report.provenance_level,
      dangerous_command_flags: public_dangerous_flags(report.dangerous_command_flags),
      health_status: report.health_status,
      health_diagnostics: report.health_diagnostics || %{},
      tool_definition_hash: report.tool_definition_hash,
      metadata_authority: report.metadata_authority,
      diagnostics: report.diagnostics || %{},
      evaluated_at: datetime_to_iso(report.evaluated_at)
    }
  end

  def evaluation_to_map(report) when is_map(report) do
    Map.take(report, [
      :id,
      :candidate_id,
      :provider,
      :remote_server_id,
      :provenance_level,
      :dangerous_command_flags,
      :health_status,
      :health_diagnostics,
      :tool_definition_hash,
      :metadata_authority,
      :diagnostics,
      :evaluated_at
    ])
    |> Map.update(:evaluated_at, nil, &datetime_to_iso/1)
  end

  defp public_dangerous_flags(flags) do
    flags
    |> case do
      %{"flags" => flags} when is_list(flags) -> flags
      %{flags: flags} when is_list(flags) -> flags
      flags when is_list(flags) -> flags
      _other -> []
    end
    |> Enum.map(fn
      %{"reason" => reason, "path" => path, "value_preview" => value_preview} ->
        %{reason: reason, path: path, value_preview: value_preview}

      %{reason: _reason, path: _path, value_preview: _value_preview} = flag ->
        flag

      other ->
        %{reason: inspect(other), path: "", value_preview: ""}
    end)
  end

  @doc "Persist an inert suggestion for later operator review."
  def upsert_suggestion(candidate_id, candidate_snapshot, evaluation_snapshot, attrs \\ %{})
      when is_binary(candidate_id) and is_map(candidate_snapshot) and is_map(evaluation_snapshot) do
    suggestion_id = "suggestion:#{candidate_id}"

    record_attrs =
      %{
        id: suggestion_id,
        candidate_id: candidate_id,
        suggestion_type: "mcp_server_candidate",
        status: Map.get(attrs, :status, "pending"),
        candidate_snapshot: candidate_snapshot,
        evaluation_snapshot: evaluation_snapshot,
        metadata: Map.get(attrs, :metadata, %{})
      }
      |> json_safe_attrs([:candidate_snapshot, :evaluation_snapshot, :metadata])

    case Repo.get(Suggestion, suggestion_id) do
      nil -> %Suggestion{} |> Suggestion.changeset(record_attrs) |> Repo.insert()
      %Suggestion{} = record -> record |> Suggestion.changeset(record_attrs) |> Repo.update()
    end
  end

  @doc "Persist the current tool-definition hash as an untrusted baseline."
  def upsert_baseline_trust_record(candidate_id, report, attrs \\ %{})
      when is_binary(candidate_id) and is_map(report) do
    record_id = "baseline:#{candidate_id}"

    record_attrs =
      %{
        id: record_id,
        candidate_id: candidate_id,
        tool_definition_hash: Map.fetch!(report, :tool_definition_hash),
        trust_status: Map.get(attrs, :trust_status, "untrusted"),
        provenance_level: Map.fetch!(report, :provenance_level),
        recorded_by: Map.get(attrs, :recorded_by),
        metadata: Map.get(attrs, :metadata, %{})
      }
      |> json_safe_attrs([:metadata])

    case Repo.get(BaselineTrustRecord, record_id) do
      nil ->
        %BaselineTrustRecord{}
        |> BaselineTrustRecord.changeset(record_attrs)
        |> Repo.insert()

      %BaselineTrustRecord{} = record ->
        record
        |> BaselineTrustRecord.changeset(record_attrs)
        |> Repo.update()
    end
  end

  defp candidate_attrs(%ToolCandidate{} = candidate, attrs, now) do
    provenance = candidate.provenance || %{}
    signals = candidate.signals || %{}

    %{
      id: candidate.id,
      name: candidate.name,
      description: candidate.description,
      source: Atom.to_string(candidate.source),
      usable_now: candidate.usable_now?,
      requires: Atom.to_string(candidate.requires),
      provider: provider_from(provenance),
      remote_server_id: remote_server_id_from(provenance),
      manifest_url: string_from(provenance, :manifest_url),
      server_url: string_from(signals, :server_url),
      provenance: provenance,
      signals: signals,
      registry_record: Map.get(attrs, :registry_record, Map.get(attrs, "registry_record", %{})),
      first_seen_at: now,
      last_seen_at: now
    }
  end

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value) when is_atom(field) do
    where(query, [record], field(record, ^field) == ^to_string(value))
  end

  defp provider_from(provenance), do: string_from(provenance, :provider)

  defp remote_server_id_from(provenance) do
    string_from(provenance, :remote_server_id) ||
      string_from(provenance, :server_id) ||
      string_from(provenance, :name)
  end

  defp provider_from_manifest(manifest) do
    manifest
    |> get_any(["provider", :provider])
    |> case do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp server_id(manifest) do
    get_any(manifest, ["name", :name, "id", :id, "url", :url]) || "unknown"
  end

  defp provenance_level("official", manifest) do
    if repository_url(manifest), do: "registry_with_source", else: "registry_metadata_only"
  end

  defp provenance_level("pulsemcp", manifest) do
    if repository_url(manifest), do: "aggregated_with_source", else: "registry_metadata_only"
  end

  defp provenance_level(_provider, manifest) do
    if repository_url(manifest), do: "aggregated_with_source", else: "unknown"
  end

  defp repository_url(manifest) do
    get_in(manifest, ["repository", "url"]) ||
      get_in(manifest, [:repository, :url]) ||
      get_any(manifest, ["source_code_url", :source_code_url])
  end

  defp dangerous_command_flags(manifest) do
    manifest
    |> scan_dangerous([], [])
    |> Enum.uniq_by(fn flag -> {flag.reason, flag.path, flag.value_preview} end)
    |> Enum.take(25)
  end

  defp scan_dangerous(value, path, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {key, child}, child_acc ->
      scan_dangerous(child, path ++ [to_string(key)], child_acc)
    end)
  end

  defp scan_dangerous(value, path, acc) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, index}, child_acc ->
      scan_dangerous(child, path ++ [Integer.to_string(index)], child_acc)
    end)
  end

  defp scan_dangerous(value, path, acc) when is_binary(value) do
    if command_like_path?(path) do
      flags_for_value(value, path) ++ acc
    else
      acc
    end
  end

  defp scan_dangerous(_value, _path, acc), do: acc

  defp command_like_path?(path) do
    Enum.any?(path, fn segment ->
      segment = String.downcase(segment)
      Enum.any?(@command_path_tokens, &String.contains?(segment, &1))
    end)
  end

  defp flags_for_value(value, path) do
    Enum.flat_map(@dangerous_patterns, fn {pattern, reason} ->
      if Regex.match?(pattern, value) do
        [
          %{
            reason: reason,
            path: Enum.join(path, "."),
            value_preview: preview(value)
          }
        ]
      else
        []
      end
    end)
  end

  defp health_probe(manifest, opts) do
    if truthy?(opt(opts, :probe?, false)) do
      do_health_probe(manifest, opts)
    else
      %{status: "not_probed", diagnostics: %{"reason" => "probe_not_requested"}}
    end
  end

  defp do_health_probe(manifest, opts) do
    case direct_remote_urls(manifest) do
      [] ->
        %{status: "not_probeable", diagnostics: %{"reason" => "no_direct_remote_url"}}

      [url | _rest] ->
        probe_url(url, opts)
    end
  end

  defp probe_url(url, opts) do
    with {:ok, spec} <-
           RequestSpec.normalize(%{
             method: "GET",
             url: url,
             timeout_ms: integer_opt(opts, :probe_timeout_ms, 1_000),
             max_response_bytes: integer_opt(opts, :probe_max_response_bytes, 1_024)
           }),
         {:ok, result} <- HttpClient.request(spec, plug: req_plug(opt(opts, :context, %{}))) do
      probe_result(result)
    else
      {:error, %RequestSpec{} = spec} ->
        %{
          status: "probe_denied",
          diagnostics: %{"reason" => inspect(spec.denial_reason), "url" => url}
        }

      {:error, reason} ->
        %{status: "unreachable", diagnostics: %{"reason" => inspect(reason), "url" => url}}
    end
  end

  defp probe_result(%{status: :completed, http_status: status}) do
    %{status: "reachable", diagnostics: %{"http_status" => status}}
  end

  defp probe_result(%{http_status: status}) when is_integer(status) do
    %{status: "http_error", diagnostics: %{"http_status" => status}}
  end

  defp probe_result(%{transport_error: reason}) do
    %{status: "unreachable", diagnostics: %{"transport_error" => reason}}
  end

  defp probe_result(result),
    do: %{status: "unreachable", diagnostics: %{"result" => inspect(result)}}

  defp direct_remote_urls(manifest) do
    remote_urls(manifest) ++ package_transport_urls(manifest)
  end

  defp remote_urls(manifest) do
    manifest
    |> get_any(["remotes", :remotes])
    |> list_value()
    |> Enum.flat_map(fn remote ->
      [
        get_any(remote, ["url_direct", :url_direct]),
        get_any(remote, ["direct_url", :direct_url])
      ]
    end)
    |> valid_urls()
  end

  defp package_transport_urls(manifest) do
    manifest
    |> get_any(["packages", :packages])
    |> list_value()
    |> Enum.flat_map(fn package ->
      transport = get_any(package, ["transport", :transport]) || %{}

      [
        get_any(transport, ["url", :url]),
        get_any(transport, ["endpoint", :endpoint]),
        get_any(transport, ["base_url", :base_url, "baseUrl", :baseUrl])
      ]
    end)
    |> valid_urls()
  end

  defp valid_urls(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, ["http://", "https://"]))
  end

  defp tool_definition_basis(manifest) do
    %{
      "name" => get_any(manifest, ["name", :name]),
      "version" => get_any(manifest, ["version", :version]),
      "packages" => get_any(manifest, ["packages", :packages]) || [],
      "remotes" => get_any(manifest, ["remotes", :remotes]) || [],
      "tools" =>
        manifest
        |> get_any(["tools", :tools])
        |> list_value()
        |> Enum.map(&tool_definition/1)
    }
  end

  defp tool_definition(tool) when is_map(tool) do
    %{
      "name" => get_any(tool, ["name", :name]),
      "description" => get_any(tool, ["description", :description]),
      "input_schema" =>
        get_any(tool, ["inputSchema", :inputSchema, "input_schema", :input_schema]) || %{}
    }
  end

  defp tool_definition(tool),
    do: %{"name" => to_string(tool), "description" => "", "input_schema" => %{}}

  defp stable_hash(value) do
    value
    |> canonical_value()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp evaluation_id(candidate_id, _provider, _server_id, _hash)
       when is_binary(candidate_id) and candidate_id != "" do
    "eval:#{candidate_id}"
  end

  defp evaluation_id(_candidate_id, provider, server_id, hash) do
    slug =
      [provider || "registry", server_id || "server"]
      |> Enum.join(":")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.:-]+/, "-")
      |> String.trim("-")

    "eval:#{slug}:#{binary_part(hash, 0, 12)}"
  end

  defp canonical_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {to_string(key), canonical_value(child)} end)
    |> Enum.sort_by(fn {key, _child} -> key end)
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_value(value), do: value

  defp json_safe_attrs(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &json_safe/1), else: acc
    end)
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {to_string(key), json_safe(child)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value), do: value

  defp datetime_to_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_to_iso(value), do: value

  defp get_any(nil, _keys), do: nil

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_value, _keys), do: nil

  defp string_from(map, key) when is_map(map) do
    get_any(map, [key, Atom.to_string(key)])
    |> case do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp string_opt(opts, key) do
    case opt(opts, key, nil) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp integer_opt(opts, key, default) do
    case opt(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))

  defp opt(_opts, _key, default), do: default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp preview(value) when is_binary(value) do
    if byte_size(value) > 160, do: binary_part(value, 0, 160), else: value
  end

  defp req_plug(context) do
    get_in(context, [:mcp, :req_plug]) ||
      get_in(context, ["mcp", "req_plug"]) ||
      get_in(context, [:external, :req_plug]) ||
      get_in(context, ["external", "req_plug"])
  end
end
