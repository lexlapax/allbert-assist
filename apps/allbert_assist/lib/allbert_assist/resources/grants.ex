defmodule AllbertAssist.Resources.Grants do
  @moduledoc """
  Settings-backed remembered resource grants.

  A remembered grant is operation-scoped resource approval memory. It can only
  match a current resource reference after Security Central policy, expiry,
  revocation, and canonical resource scope are re-checked.
  """

  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @setting_key "resource_grants.remembered"

  @url_scopes [:exact_url, :url_prefix]
  @source_fingerprint_keys [:base_url, :api_url, :url]

  @doc "Settings Central key that stores remembered resource grants."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting_key

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    case Settings.get(@setting_key) do
      {:ok, grants} when is_list(grants) -> {:ok, Enum.map(grants, &stringify_record/1)}
      {:ok, other} -> {:error, {:invalid_resource_grants, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(id) when is_binary(id) do
    with {:ok, grants} <- list() do
      case Enum.find(grants, &(Map.get(&1, "id") == id)) do
        nil -> {:error, {:grant_not_found, id}}
        grant -> {:ok, grant}
      end
    end
  end

  @spec remember(map() | Ref.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def remember(resource_ref, attrs \\ %{}) do
    attrs = attrs_map(attrs)

    with {:ok, grant} <- build_record(resource_ref, attrs),
         {:ok, grants} <- list(),
         {:ok, _setting} <- Settings.put(@setting_key, grants ++ [grant], settings_context(attrs)) do
      {:ok, grant}
    end
  end

  @spec revoke(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def revoke(id, attrs \\ %{}) when is_binary(id) do
    attrs = attrs_map(attrs)
    revoked_at = datetime_text(field(attrs, :revoked_at) || DateTime.utc_now())

    with {:ok, grants} <- list(),
         {:ok, grant, updated} <- revoke_grant(grants, id, revoked_at),
         {:ok, _setting} <- Settings.put(@setting_key, updated, settings_context(attrs)) do
      {:ok, grant}
    end
  end

  @doc """
  Find a currently applicable remembered grant for a resource reference.

  The caller must pass the current action permission with `permission: ...`.
  `:needs_confirmation` policy decisions are allowed because a matching
  remembered grant may satisfy the confirmation requirement. `:denied` policy
  decisions always block the grant.
  """
  @spec find_applicable(map() | Ref.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def find_applicable(resource_ref, opts \\ %{}) do
    opts = attrs_map(opts)

    with {:ok, normalized_ref} <- normalize_ref(resource_ref),
         :ok <- policy_allows?(normalized_ref, opts),
         {:ok, grants} <- list() do
      grants
      |> evaluate_grants(normalized_ref, opts)
      |> case do
        {:matched, grant} -> {:ok, grant}
        {:rejected, reason} -> {:error, reason}
        :no_match -> {:error, :no_matching_grant}
      end
    end
  end

  @doc "Return v0.11 Approval Handoff remember-scope choices as plain data."
  @spec remember_options(map() | Ref.t()) :: {:ok, [map()]} | {:error, term()}
  def remember_options(resource_ref) do
    with {:ok, ref} <- normalize_ref(resource_ref) do
      {:ok,
       ref
       |> option_scopes()
       |> Enum.map(&remember_option(ref, &1))}
    end
  end

  defp build_record(resource_ref, attrs) do
    with {:ok, ref} <- normalize_ref(resource_ref) do
      now = datetime_text(field(attrs, :created_at) || DateTime.utc_now())
      scope = %{"kind" => Atom.to_string(ref.scope_kind), "value" => ref.resource_uri}

      {:ok,
       %{
         "id" => to_string(field(attrs, :id) || grant_id()),
         "resource_uri" => ref.resource_uri,
         "origin_kind" => Atom.to_string(ref.origin_kind),
         "scope" => scope,
         "operation_class" => Atom.to_string(ref.operation_class),
         "access_mode" => Atom.to_string(ref.access_mode),
         "created_at" => now,
         "metadata" => grant_metadata(ref, field(attrs, :metadata, %{}))
       }
       |> maybe_put_string("downstream_consumer", ref.downstream_consumer)
       |> maybe_put_string("action_permission", field(attrs, :action_permission))
       |> maybe_put_string("origin_channel", field(attrs, :origin_channel))
       |> maybe_put_string("resolver_channel", field(attrs, :resolver_channel))
       |> maybe_put_datetime("expires_at", field(attrs, :expires_at))
       |> maybe_put_datetime("revoked_at", field(attrs, :revoked_at))
       |> maybe_put_string("audit_path", field(attrs, :audit_path))
       |> maybe_put_string("reason", field(attrs, :reason))}
    end
  end

  defp normalize_ref(%Ref{} = ref), do: ref |> Ref.to_map() |> normalize_ref()

  defp normalize_ref(resource_ref) when is_map(resource_ref) do
    with {:ok, ref} <- Ref.new(resource_ref),
         {:ok, resource_uri} <-
           ResourceURI.scope_uri(
             ref.origin_kind,
             ref.scope.kind,
             ref.scope.value,
             ref.resource_uri
           ) do
      {:ok,
       %{
         resource_uri: resource_uri,
         origin_kind: ref.origin_kind,
         operation_class: ref.operation_class,
         access_mode: ref.access_mode,
         scope_kind: ref.scope.kind,
         downstream_consumer: normalize_optional_string(ref.downstream_consumer),
         metadata: ref.metadata
       }}
    end
  end

  defp normalize_ref(resource_ref), do: {:error, {:invalid_resource_ref, resource_ref}}

  defp policy_allows?(_ref, opts) do
    case field(opts, :permission) do
      nil ->
        {:error, :permission_required}

      permission ->
        decision = PermissionGate.authorize(permission, field(opts, :context, %{}))

        if decision.decision == :denied do
          {:error, {:policy_denied, decision}}
        else
          :ok
        end
    end
  end

  defp evaluate_grants(grants, ref, opts) do
    grants
    |> Enum.reduce({[], []}, fn grant, {matches, rejections} ->
      case evaluate_grant(grant, ref, opts) do
        {:match, grant} -> {[grant | matches], rejections}
        {:reject, reason} -> {matches, [reason | rejections]}
        :no_match -> {matches, rejections}
      end
    end)
    |> case do
      {[grant | _rest], _rejections} -> {:matched, grant}
      {[], [reason | _rest]} -> {:rejected, reason}
      {[], []} -> :no_match
    end
  end

  defp evaluate_grant(grant, ref, opts) do
    grant = stringify_record(grant)

    cond do
      not same_boundary?(grant, ref) ->
        :no_match

      not scope_matches?(grant, ref) ->
        :no_match

      revoked?(grant) ->
        {:reject, {:grant_revoked, grant["id"]}}

      expired?(grant, opts) ->
        {:reject, {:grant_expired, grant["id"]}}

      source_profile_drifted?(grant, ref) ->
        {:reject, {:source_profile_drift, grant["id"]}}

      redirect_outside?(grant, opts) ->
        {:reject, {:redirect_outside_scope, redirect_url(ref, opts)}}

      true ->
        {:match, grant}
    end
  end

  defp same_boundary?(grant, ref) do
    grant["operation_class"] == Atom.to_string(ref.operation_class) and
      grant["access_mode"] == Atom.to_string(ref.access_mode) and
      Map.get(grant, "downstream_consumer") == ref.downstream_consumer
  end

  defp scope_matches?(%{"scope" => %{"kind" => "exact_file"}} = grant, ref) do
    ref.scope_kind == :exact_file and ref.resource_uri == grant["resource_uri"]
  end

  defp scope_matches?(%{"scope" => %{"kind" => kind}} = grant, ref)
       when kind in ["directory_subtree", "package_target_root"] do
    with true <- ref.scope_kind in [:exact_file, :directory_subtree, :package_target_root],
         {:ok, ref_path} <- ResourceURI.path_from_file_uri(ref.resource_uri),
         {:ok, grant_path} <- ResourceURI.path_from_file_uri(grant["resource_uri"]) do
      path_within?(ref_path, grant_path)
    else
      _other -> false
    end
  end

  defp scope_matches?(%{"scope" => %{"kind" => "exact_url"}} = grant, ref) do
    ref.scope_kind == :exact_url and ref.resource_uri == grant["resource_uri"]
  end

  defp scope_matches?(%{"scope" => %{"kind" => "url_prefix"}} = grant, ref) do
    ref.scope_kind in @url_scopes and
      url_prefix_match?(grant["resource_uri"], ref.resource_uri)
  end

  defp scope_matches?(%{"scope" => %{"kind" => kind}} = grant, ref)
       when kind in ["source_profile", "skill_resource_id"] do
    Atom.to_string(ref.scope_kind) == kind and ref.resource_uri == grant["resource_uri"]
  end

  defp scope_matches?(_grant, _ref), do: false

  defp source_profile_drifted?(%{"scope" => %{"kind" => "source_profile"}} = grant, ref) do
    grant_fingerprint = get_in(grant, ["metadata", "source_fingerprint"])

    cond do
      grant_fingerprint in [nil, %{}] ->
        false

      ref_fingerprint = source_fingerprint(ref.metadata) ->
        stringify_record(ref_fingerprint) != grant_fingerprint

      true ->
        true
    end
  end

  defp source_profile_drifted?(_grant, _ref), do: false

  defp path_within?(path, root) do
    path == root or String.starts_with?(path, ensure_trailing_slash(root))
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp url_prefix_match?(prefix, candidate) do
    prefix_uri = URI.parse(prefix)
    candidate_uri = URI.parse(candidate)

    same_url_authority?(prefix_uri, candidate_uri) and
      path_prefix_match?(prefix_uri.path || "/", candidate_uri.path || "/")
  end

  defp same_url_authority?(left, right) do
    left.scheme == right.scheme and left.host == right.host and left.port == right.port
  end

  defp path_prefix_match?("/", _candidate_path), do: true

  defp path_prefix_match?(prefix_path, candidate_path) do
    candidate_path == prefix_path or
      String.starts_with?(candidate_path, ensure_trailing_slash(prefix_path))
  end

  defp revoked?(grant), do: present?(Map.get(grant, "revoked_at"))

  defp expired?(grant, opts) do
    case Map.get(grant, "expires_at") do
      nil ->
        false

      "" ->
        false

      expires_at ->
        {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)
        DateTime.compare(expires_at, now(opts)) != :gt
    end
  end

  defp redirect_outside?(grant, opts) do
    redirect = redirect_url(nil, opts)

    redirect != nil and url_scope?(grant) and not redirect_matches_scope?(grant, redirect)
  end

  defp redirect_url(_ref, opts), do: field(opts, :redirect_url)

  defp url_scope?(%{"scope" => %{"kind" => kind}}), do: kind in ["exact_url", "url_prefix"]
  defp url_scope?(_grant), do: false

  defp redirect_matches_scope?(%{"scope" => %{"kind" => "exact_url"}} = grant, redirect) do
    case ResourceURI.url(redirect, :exact) do
      {:ok, canonical} -> canonical == grant["resource_uri"]
      {:error, _reason} -> false
    end
  end

  defp redirect_matches_scope?(%{"scope" => %{"kind" => "url_prefix"}} = grant, redirect) do
    case ResourceURI.url(redirect, :exact) do
      {:ok, canonical} -> url_prefix_match?(grant["resource_uri"], canonical)
      {:error, _reason} -> false
    end
  end

  defp revoke_grant(grants, id, revoked_at) do
    case Enum.split_with(grants, &(Map.get(&1, "id") == id)) do
      {[], _other} ->
        {:error, {:grant_not_found, id}}

      {[grant | _duplicates], rest} ->
        updated_grant = Map.put(grant, "revoked_at", revoked_at)
        {:ok, updated_grant, [updated_grant | rest]}
    end
  end

  defp option_scopes(ref) do
    exact_scope = %{"kind" => Atom.to_string(ref.scope_kind), "value" => ref.resource_uri}

    [exact_scope]
    |> maybe_add_parent_scope(ref)
    |> Enum.uniq()
  end

  defp maybe_add_parent_scope(scopes, %{scope_kind: :exact_file, resource_uri: resource_uri}) do
    case ResourceURI.path_from_file_uri(resource_uri) do
      {:ok, path} ->
        [
          %{"kind" => "directory_subtree", "value" => ResourceURI.file!(Path.dirname(path))}
          | scopes
        ]

      {:error, _reason} ->
        scopes
    end
  end

  defp maybe_add_parent_scope(scopes, %{scope_kind: :exact_url, resource_uri: url}) do
    case ResourceURI.url(url, :prefix) do
      {:ok, prefix} -> [%{"kind" => "url_prefix", "value" => prefix} | scopes]
      {:error, _reason} -> scopes
    end
  end

  defp maybe_add_parent_scope(scopes, _ref), do: scopes

  defp remember_option(ref, scope) do
    %{
      label: option_label(scope),
      origin_kind: Atom.to_string(ref.origin_kind),
      scope: scope,
      operation_class: Atom.to_string(ref.operation_class),
      access_mode: Atom.to_string(ref.access_mode),
      downstream_consumer: ref.downstream_consumer
    }
    |> drop_nil_values()
  end

  defp option_label(%{"kind" => "exact_file"}), do: "Remember exact file for this operation"
  defp option_label(%{"kind" => "directory_subtree"}), do: "Remember directory for this operation"
  defp option_label(%{"kind" => "exact_url"}), do: "Remember exact URL for this operation"
  defp option_label(%{"kind" => "url_prefix"}), do: "Remember URL prefix for this operation"

  defp option_label(%{"kind" => "source_profile"}),
    do: "Remember source profile for this operation"

  defp option_label(%{"kind" => "package_target_root"}),
    do: "Remember package target root for this operation"

  defp option_label(_scope), do: "Remember resource for this operation"

  defp settings_context(attrs) do
    attrs
    |> Map.take([:actor, :channel, :surface, :audit?])
    |> Map.put_new(:actor, "local")
    |> Map.put_new(:channel, :resource_grants)
  end

  defp grant_id do
    "grant_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"
  end

  defp now(opts), do: field(opts, :now) || DateTime.utc_now()

  defp datetime_text(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_text(value) when is_binary(value), do: value
  defp datetime_text(nil), do: nil

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, to_string(value))

  defp maybe_put_datetime(map, _key, nil), do: map
  defp maybe_put_datetime(map, key, value), do: Map.put(map, key, datetime_text(value))

  defp grant_metadata(ref, metadata) do
    metadata
    |> stringify_metadata()
    |> maybe_put_source_fingerprint(ref)
  end

  defp maybe_put_source_fingerprint(metadata, %{scope_kind: :source_profile} = ref) do
    case source_fingerprint(ref.metadata) do
      nil -> metadata
      fingerprint -> Map.put(metadata, "source_fingerprint", stringify_record(fingerprint))
    end
  end

  defp maybe_put_source_fingerprint(metadata, _ref), do: metadata

  defp source_fingerprint(metadata) when is_map(metadata) do
    @source_fingerprint_keys
    |> Enum.reduce(%{}, fn key, acc ->
      value = field(metadata, key)
      value = normalize_fingerprint_value(value)

      if value in [nil, ""] do
        acc
      else
        Map.put(acc, key |> to_string() |> String.trim(), value)
      end
    end)
    |> case do
      empty when empty == %{} -> nil
      fingerprint -> fingerprint
    end
  end

  defp normalize_fingerprint_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_fingerprint_value(nil), do: nil
  defp normalize_fingerprint_value(value), do: value |> to_string() |> String.trim()

  defp stringify_record(record) when is_map(record) do
    record
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_value(value) when is_map(value), do: stringify_record(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp stringify_metadata(metadata) when is_map(metadata), do: stringify_record(metadata)
  defp stringify_metadata(_metadata), do: %{}

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_string(value), do: to_string(value)

  defp present?(value), do: value not in [nil, ""]

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end
end
