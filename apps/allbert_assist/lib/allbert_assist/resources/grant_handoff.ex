defmodule AllbertAssist.Resources.GrantHandoff do
  @moduledoc """
  Shared remembered-grant handoff helpers for v0.10 actions and operator surfaces.

  The helpers keep grant lookup and approval-time remembering generic over
  resource refs. They do not execute work and they do not own security policy;
  callers still pass the current action permission so Security Central is
  re-checked by `AllbertAssist.Resources.Grants`.
  """

  alias AllbertAssist.Resources.Grants

  @none [nil, "", "none", :none, false]
  @scope_aliases %{
    "exact" => :exact,
    "parent" => :parent,
    "directory" => "directory_subtree",
    "directory-subtree" => "directory_subtree",
    "directory_subtree" => "directory_subtree",
    "url-prefix" => "url_prefix",
    "url_prefix" => "url_prefix",
    "source-profile" => "source_profile",
    "source_profile" => "source_profile",
    "package-target-root" => "package_target_root",
    "package_target_root" => "package_target_root",
    "mcp-server" => "mcp_server",
    "mcp_server" => "mcp_server",
    "mcp-tool" => "mcp_tool",
    "mcp_tool" => "mcp_tool"
  }

  @spec find_applicable([map()] | nil, atom(), map()) ::
          {:ok, [map()]} | :no_match | {:error, term()}
  def find_applicable(resource_refs, permission, context) do
    refs = resource_refs |> List.wrap() |> Enum.reject(&blank?/1)
    match_all_refs(refs, permission, context)
  end

  defp match_all_refs([], _permission, _context), do: :no_match

  defp match_all_refs(refs, permission, context) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, grants} ->
      case Grants.find_applicable(ref, permission: permission, context: context) do
        {:ok, grant} -> {:cont, {:ok, [grant | grants]}}
        {:error, {:policy_denied, _decision} = reason} -> {:halt, {:error, reason}}
        {:error, _reason} -> {:halt, :no_match}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, unique_grants(Enum.reverse(grants))}
      other -> other
    end
  end

  @spec put_applied(map(), [map()]) :: map()
  def put_applied(context, grants) when is_list(grants) do
    Map.put(context, :resource_grants, %{
      applied?: true,
      grants: Enum.map(grants, &summary/1)
    })
  end

  def action_metadata(context) do
    case Map.get(context, :resource_grants) do
      %{applied?: true, grants: grants} ->
        %{resource_grants: %{applied?: true, grants: grants, grant_ids: grant_ids(grants)}}

      _other ->
        %{}
    end
  end

  @spec target_resumed?(map()) :: boolean()
  def target_resumed?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  @spec remember_from_confirmation(map(), map() | keyword(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def remember_from_confirmation(record, attrs, context \\ %{}) when is_map(record) do
    attrs = attrs_map(attrs)
    scope = normalize_scope(field(attrs, :remember_scope) || field(attrs, :scope))

    if scope in @none do
      {:ok, []}
    else
      refs = resource_refs(record)

      refs
      |> selected_refs(attrs)
      |> remember_selected(record, attrs, context, scope)
    end
  end

  @spec summary(map()) :: map()
  def summary(grant) when is_map(grant) do
    grant
    |> stringify_record()
    |> Map.take([
      "id",
      "resource_uri",
      "origin_kind",
      "scope",
      "operation_class",
      "access_mode",
      "downstream_consumer",
      "action_permission",
      "origin_channel",
      "resolver_channel",
      "created_at",
      "expires_at",
      "revoked_at",
      "audit_path",
      "reason",
      "metadata"
    ])
  end

  defp remember_selected([], _record, _attrs, _context, _scope) do
    {:error, :resource_ref_not_found}
  end

  defp remember_selected(refs, record, attrs, context, scope) do
    refs
    |> Enum.reduce_while({:ok, []}, fn {ref, index}, {:ok, grants} ->
      with {:ok, selected_ref} <- ref_for_scope(ref, scope),
           {:ok, grant} <-
             Grants.remember(selected_ref, remember_attrs(record, attrs, context, index)) do
        {:cont, {:ok, [grant | grants]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, Enum.reverse(grants)}
      error -> error
    end
  end

  defp selected_refs(refs, attrs) do
    refs = Enum.with_index(refs)

    if truthy?(field(attrs, :remember_all)) do
      refs
    else
      index = parse_index(field(attrs, :resource_index, 0))

      refs
      |> Enum.find(fn {_ref, ref_index} -> ref_index == index end)
      |> case do
        nil -> []
        ref -> [ref]
      end
    end
  end

  defp ref_for_scope(ref, scope) do
    with {:ok, options} <- Grants.remember_options(ref),
         {:ok, option} <- select_option(options, ref, scope) do
      {:ok, put_scope(ref, field(option, :scope))}
    end
  end

  defp select_option(options, ref, :exact) do
    current_scope_kind = ref |> field(:scope, %{}) |> field(:kind) |> to_string()

    find_option(options, current_scope_kind) ||
      {:error, {:remember_scope_unavailable, "exact"}}
  end

  defp select_option(options, ref, :parent) do
    current_scope_kind = ref |> field(:scope, %{}) |> field(:kind) |> to_string()

    options
    |> Enum.find(fn option ->
      option |> field(:scope, %{}) |> field(:kind) != current_scope_kind
    end)
    |> case do
      nil -> {:error, {:remember_scope_unavailable, "parent"}}
      option -> {:ok, option}
    end
  end

  defp select_option(options, _ref, scope) do
    find_option(options, scope) ||
      {:error, {:remember_scope_unavailable, scope}}
  end

  defp find_option(options, scope) do
    scope = to_string(scope)

    options
    |> Enum.find(fn option ->
      option |> field(:scope, %{}) |> field(:kind) |> to_string() == scope
    end)
    |> case do
      nil -> nil
      option -> {:ok, option}
    end
  end

  defp put_scope(ref, scope) when is_map(ref) do
    if Map.has_key?(ref, :scope) do
      Map.put(ref, :scope, scope)
    else
      Map.put(ref, "scope", scope)
    end
  end

  defp remember_attrs(record, attrs, context, index) do
    metadata =
      %{
        confirmation_id: Map.get(record, "id"),
        target_action: get_in(record, ["target_action", "name"]),
        resource_index: index
      }
      |> Map.merge(field(attrs, :metadata, %{}) || %{})

    %{
      reason: field(attrs, :reason),
      expires_at: field(attrs, :expires_at),
      audit_path: Map.get(record, "audit_path"),
      action_permission: Map.get(record, "target_permission"),
      origin_channel: get_in(record, ["origin", "channel"]),
      resolver_channel: channel(context),
      actor: actor(context),
      channel: channel(context),
      surface: surface(context),
      metadata: metadata
    }
    |> put_if_present(:id, field(attrs, :grant_id))
    |> put_if_present(:audit?, field(attrs, :audit?))
  end

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp resource_refs(record) do
    record
    |> get_in(["params_summary", "resource_refs"])
    |> List.wrap()
    |> Enum.reject(&blank?/1)
  end

  defp unique_grants(grants) do
    grants
    |> Enum.uniq_by(&Map.get(&1, "id"))
  end

  defp grant_ids(grants), do: Enum.map(grants, &Map.get(&1, "id"))

  defp normalize_scope(scope) when scope in @none, do: scope

  defp normalize_scope(scope) do
    normalized = scope |> to_string() |> String.trim() |> String.downcase()
    Map.get(@scope_aliases, normalized, String.trim(to_string(scope)))
  end

  defp parse_index(value) when is_integer(value), do: value

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 -> index
      _other -> 0
    end
  end

  defp parse_index(_value), do: 0

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes", "all"]

  defp blank?(value), do: value in [nil, "", %{}, []]

  defp actor(context), do: field(context, :actor, "local")
  defp channel(context), do: field(context, :channel, :unknown)
  defp surface(context), do: field(context, :surface, "resource_grants")

  defp stringify_record(record) when is_map(record) do
    Map.new(record, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_record(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
