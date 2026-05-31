defmodule AllbertAssist.Tools.Source.Local do
  @moduledoc """
  Local tool-discovery source over registered actions, skills, and configured MCP tools.
  """

  @behaviour AllbertAssist.Tools.SourcePort

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Mcp
  alias AllbertAssist.Settings.Store, as: SettingsStore
  alias AllbertAssist.Skills.Registry, as: SkillsRegistry
  alias AllbertAssist.Tools.ToolCandidate

  @default_limit 25
  @max_limit 100

  @impl true
  def source_id, do: :local

  @impl true
  def search(query, opts \\ %{})

  def search(query, opts) when is_binary(query) and is_map(opts) do
    with {:ok, %{candidates: candidates}} <- search_with_diagnostics(query, opts) do
      {:ok, candidates}
    end
  end

  def search(query, opts) when is_map(opts), do: search(to_string(query || ""), opts)

  def search_with_diagnostics(query, opts \\ %{})

  def search_with_diagnostics(query, opts) when is_binary(query) and is_map(opts) do
    context = context(opts)
    limit = limit(opts)
    {skills, diagnostics} = skill_candidates(context)

    candidates =
      action_candidates() ++
        skills ++
        configured_mcp_candidates(query, context)

    candidates
    |> Enum.filter(&matches?(&1, query))
    |> Enum.sort_by(&rank_key(&1, query))
    |> Enum.take(limit)
    |> then(&{:ok, %{candidates: &1, diagnostics: diagnostics}})
  end

  def search_with_diagnostics(query, opts) when is_map(opts),
    do: search_with_diagnostics(to_string(query || ""), opts)

  defp action_candidates do
    ActionsRegistry.capabilities()
    |> Enum.map(&action_candidate/1)
    |> Enum.flat_map(&ok_list/1)
  end

  defp action_candidate(capability) do
    metadata = action_metadata(capability.module)

    ToolCandidate.normalize(%{
      id: "action:#{capability.name}",
      name: capability.name,
      description: metadata.description || capability.name,
      source: :local_action,
      provenance: %{
        module: inspect(capability.module),
        app_id: capability.app_id,
        plugin_id: capability.plugin_id
      },
      signals: %{
        kind: :action,
        category: metadata.category,
        tags: metadata.tags,
        permission: capability.permission,
        exposure: capability.exposure,
        execution_mode: capability.execution_mode,
        skill_backed?: capability.skill_backed?
      }
    })
  end

  defp action_metadata(module) do
    if function_exported?(module, :__action_metadata__, 0) do
      module.__action_metadata__()
      |> normalize_metadata()
    else
      %{description: nil, category: nil, tags: []}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    %{
      description: field(metadata, :description),
      category: field(metadata, :category),
      tags: field(metadata, :tags, [])
    }
  end

  defp normalize_metadata(_metadata), do: %{description: nil, category: nil, tags: []}

  defp skill_candidates(context) do
    case skill_registry(context).list(context) do
      {:ok, skills} ->
        candidates =
          skills
          |> Enum.map(&skill_candidate/1)
          |> Enum.flat_map(&ok_list/1)

        {candidates, []}

      {:error, reason} ->
        {[], [diagnostic(:local_skill, :degraded, reason)]}
    end
  rescue
    exception ->
      {[],
       [
         diagnostic(:local_skill, :degraded, {exception.__struct__, Exception.message(exception)})
       ]}
  end

  defp skill_candidate(skill) do
    ToolCandidate.normalize(%{
      id: "skill:#{skill.name}",
      name: skill.name,
      description: skill.description,
      source: :local_skill,
      provenance: %{
        source_scope: skill.source_scope,
        source_path: skill.source_path,
        plugin_id: skill.plugin_id
      },
      signals: %{
        kind: :skill,
        title: skill.title,
        permission: skill.permission,
        status: skill.status,
        aliases: skill.aliases,
        trust_status: skill.trust_status
      }
    })
  end

  defp configured_mcp_candidates(query, context) do
    if configured_mcp_enabled?(context) do
      context
      |> enabled_server_ids()
      |> Enum.flat_map(&configured_mcp_server_candidates(&1, query, context))
    else
      []
    end
  end

  defp configured_mcp_server_candidates(server_id, _query, context) do
    case Mcp.list_tools(server_id, context, cursor: nil) do
      {:ok, result} ->
        result
        |> Map.get(:tools, [])
        |> Enum.map(&configured_mcp_candidate(server_id, &1, result))
        |> Enum.flat_map(&ok_list/1)

      {:error, _reason} ->
        []
    end
  end

  defp configured_mcp_candidate(server_id, tool, result) when is_map(tool) do
    tool_name = Map.get(tool, "name") || Map.get(tool, :name)

    ToolCandidate.normalize(%{
      id: "mcp:#{server_id}:tool:#{tool_name}",
      name: "#{server_id}:#{tool_name}",
      description: Map.get(tool, "description") || Map.get(tool, :description) || "",
      source: :configured_mcp,
      provenance: %{
        server_id: server_id,
        protocol_version: Map.get(result, :protocol_version)
      },
      signals: %{
        kind: :configured_mcp_tool,
        input_schema?: not is_nil(Map.get(tool, "inputSchema") || Map.get(tool, :input_schema))
      }
    })
  end

  defp configured_mcp_candidate(_server_id, _tool, _result), do: {:error, :invalid_tool}

  defp enabled_server_ids(context) do
    servers =
      case Map.get(context, :mcp_servers) || Map.get(context, "mcp_servers") do
        servers when is_map(servers) -> servers
        _other -> settings_servers()
      end

    servers
    |> Enum.filter(fn {_server_id, attrs} -> enabled_server?(attrs) end)
    |> Enum.map(fn {server_id, _attrs} -> server_id end)
    |> Enum.sort()
  end

  defp settings_servers do
    case SettingsStore.resolved_settings() do
      {:ok, settings, _user_settings} -> get_in(settings, ["mcp", "servers"]) || %{}
      {:error, _reason} -> %{}
    end
  end

  defp enabled_server?(attrs) when is_map(attrs) do
    Map.get(attrs, "enabled") == true or Map.get(attrs, :enabled) == true
  end

  defp enabled_server?(_attrs), do: false

  defp configured_mcp_enabled?(context) do
    Map.get(context, :include_configured_mcp?, Map.get(context, "include_configured_mcp?", true))
  end

  defp skill_registry(context) do
    Map.get(context, :skills_registry, Map.get(context, "skills_registry", SkillsRegistry))
  end

  defp matches?(_candidate, query) when query in [nil, ""], do: true

  defp matches?(%ToolCandidate{} = candidate, query) do
    query_tokens = tokens(query)
    text_tokens = candidate |> searchable_text() |> tokens()

    query_tokens == [] or Enum.all?(query_tokens, &(&1 in text_tokens))
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

    {score, source_order(candidate.source), normalized_name, candidate.id}
  end

  defp source_order(:local_action), do: 0
  defp source_order(:local_skill), do: 1
  defp source_order(:configured_mcp), do: 2
  defp source_order(_source), do: 9

  defp searchable_text(%ToolCandidate{} = candidate) do
    [
      candidate.name,
      candidate.description,
      inspect(candidate.provenance),
      inspect(candidate.signals)
    ]
    |> Enum.join(" ")
  end

  defp tokens(value) do
    value
    |> normalize()
    |> String.split(" ", trim: true)
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  defp context(opts), do: Map.get(opts, :context, Map.get(opts, "context", %{}))

  defp limit(opts) do
    case Map.get(opts, :limit, Map.get(opts, "limit", @default_limit)) do
      value when is_integer(value) and value > 0 -> min(value, @max_limit)
      _value -> @default_limit
    end
  end

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp ok_list({:ok, value}), do: [value]
  defp ok_list({:error, _reason}), do: []

  defp diagnostic(source, status, reason) do
    %{source: source, status: status, reason: inspect(reason)}
  end
end
