defmodule AllbertAssist.Resources.ResourceURI do
  @moduledoc """
  URI-first resource identity helpers.

  Resource URIs are inert identifiers. They do not grant permission and they do
  not imply that a scheme has an executor.
  """

  @unsupported_schemes ~w[agent agent+https]

  @type derived_fields :: %{
          required(:origin_kind) => atom(),
          required(:canonical_id) => String.t(),
          required(:unsupported?) => boolean(),
          optional(:server_id) => String.t(),
          optional(:server_resource_uri) => String.t()
        }

  @spec file(term()) :: {:ok, String.t()}
  def file(path) do
    path
    |> canonical_path()
    |> then(&{:ok, "file://" <> encode_path(&1)})
  end

  @spec file!(term()) :: String.t()
  def file!(path), do: bang(file(path))

  @spec url(term(), :exact | :prefix) :: {:ok, String.t()} | {:error, term()}
  def url(value, mode \\ :exact) do
    uri = if match?(%URI{}, value), do: value, else: URI.parse(to_string(value))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      path = if uri.path in [nil, ""], do: "/", else: uri.path
      query = if mode == :exact, do: uri.query, else: nil

      {:ok,
       [
         String.downcase(uri.scheme),
         "://",
         String.downcase(uri.host),
         port_text(uri),
         path,
         query_text(query)
       ]
       |> Enum.join("")}
    else
      {:error, {:invalid_url_uri, value}}
    end
  end

  @spec url!(term(), :exact | :prefix) :: String.t()
  def url!(value, mode \\ :exact), do: bang(url(value, mode))

  @spec source_profile(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def source_profile(kind, id) do
    with {:ok, kind} <- segment(kind, :missing_source_kind),
         {:ok, id} <- segment(id, :missing_source_id) do
      {:ok, "allbert://sources/#{kind}/#{id}"}
    end
  end

  @spec source_profile!(term(), term()) :: String.t()
  def source_profile!(kind, id), do: bang(source_profile(kind, id))

  @spec skill_resource(term()) :: {:ok, String.t()} | {:error, term()}
  def skill_resource(script_id) do
    script_id = script_id |> to_string() |> String.trim()

    case String.split(script_id, ":", parts: 2) do
      [skill_name, script_path] when skill_name != "" and script_path != "" ->
        {:ok, "skill://#{encode_segment(skill_name)}/#{encode_path(script_path)}"}

      [skill_name] when skill_name != "" ->
        {:ok, "skill://#{encode_segment(skill_name)}/"}

      _other ->
        {:error, :missing_skill_resource}
    end
  end

  @spec skill_resource!(term()) :: String.t()
  def skill_resource!(script_id), do: bang(skill_resource(script_id))

  @spec package(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def package(manager, package) do
    with {:ok, manager} <- segment(manager, :missing_package_manager),
         {:ok, package} <- non_empty(package, :missing_package) do
      {:ok, "pkg:#{manager}/#{encode_purl_path(package)}"}
    end
  end

  @spec package!(term(), term()) :: String.t()
  def package!(manager, package), do: bang(package(manager, package))

  @spec mcp(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def mcp(server_id, server_resource_uri) do
    with {:ok, server_id} <- mcp_server_id(server_id),
         {:ok, server_resource_uri} <- non_empty(server_resource_uri, :missing_mcp_resource_uri) do
      {:ok, "mcp://#{server_id}/#{encode_segment(server_resource_uri)}"}
    end
  end

  @spec mcp!(term(), term()) :: String.t()
  def mcp!(server_id, server_resource_uri), do: bang(mcp(server_id, server_resource_uri))

  @spec allbert_home(term()) :: {:ok, String.t()} | {:error, term()}
  def allbert_home(path) do
    with {:ok, path} <- non_empty(path, :missing_allbert_home_path) do
      {:ok, "allbert://home/#{path |> String.trim_leading("/") |> encode_path()}"}
    end
  end

  @spec normalize(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :missing_resource_uri}
    else
      value
      |> URI.parse()
      |> normalize_parsed(value)
    end
  end

  def normalize(nil), do: {:error, :missing_resource_uri}
  def normalize(value), do: normalize(to_string(value))

  @spec normalize!(term()) :: String.t()
  def normalize!(value), do: bang(normalize(value))

  @spec derived_fields(String.t()) :: {:ok, derived_fields()} | {:error, term()}
  def derived_fields(resource_uri) do
    with {:ok, uri} <- normalize(resource_uri) do
      uri
      |> URI.parse()
      |> derive(uri)
    end
  end

  @spec scope_uri(atom(), atom(), term(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def scope_uri(:package_registry, :source_profile, _value, resource_uri),
    do: normalize(resource_uri)

  def scope_uri(_origin_kind, kind, value, _resource_uri)
      when kind in [:exact_file, :directory_subtree, :package_target_root] do
    if scheme(value) == "file", do: normalize(value), else: file(value)
  end

  def scope_uri(_origin_kind, :exact_url, value, _resource_uri), do: url(value, :exact)
  def scope_uri(_origin_kind, :url_prefix, value, _resource_uri), do: url(value, :prefix)

  def scope_uri(:remote_source, :source_profile, value, _resource_uri) do
    if scheme(value) == "allbert",
      do: normalize(value),
      else: source_profile(:online_skill, value)
  end

  def scope_uri(origin_kind, :source_profile, value, _resource_uri) do
    if scheme(value) == "allbert", do: normalize(value), else: source_profile(origin_kind, value)
  end

  def scope_uri(_origin_kind, :skill_resource_id, value, _resource_uri) do
    if scheme(value) == "skill", do: normalize(value), else: skill_resource(value)
  end

  def scope_uri(:mcp_resource, :mcp_server, value, _resource_uri) do
    with {:ok, server_id} <- mcp_server_id(value) do
      {:ok, "mcp://#{server_id}/"}
    end
  end

  def scope_uri(:mcp_resource, :mcp_tool, value, _resource_uri) do
    with {:ok, value} <- non_empty(value, :missing_mcp_tool_scope) do
      mcp_tool_scope_uri(value)
    end
  end

  def scope_uri(_origin_kind, kind, _value, _resource_uri),
    do: {:error, {:unsupported_scope_uri, kind}}

  defp mcp_tool_scope_uri(value) do
    case String.split(value, ":", parts: 2) do
      [server_id, tool_name] ->
        with {:ok, server_id} <- mcp_server_id(server_id),
             {:ok, tool_name} <- non_empty(tool_name, :missing_mcp_tool_name) do
          {:ok, "mcp://#{server_id}/#{encode_segment("tools/" <> tool_name)}"}
        end

      _other ->
        {:error, {:invalid_mcp_tool_scope, value}}
    end
  end

  @spec path_from_file_uri(String.t()) :: {:ok, String.t()} | {:error, term()}
  def path_from_file_uri(resource_uri) do
    with {:ok, normalized} <- normalize(resource_uri),
         %URI{scheme: "file", host: host, path: path} <- URI.parse(normalized),
         true <- host in [nil, ""] || {:error, {:invalid_file_uri_host, host}},
         true <-
           (is_binary(path) and path != "") || {:error, {:invalid_file_uri_path, resource_uri}} do
      {:ok, URI.decode(path)}
    else
      %URI{} -> {:error, {:not_file_uri, resource_uri}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unsupported?(String.t()) :: boolean()
  def unsupported?(resource_uri) do
    %URI{scheme: scheme} = URI.parse(resource_uri)
    scheme in @unsupported_schemes
  end

  defp normalize_parsed(%URI{scheme: nil}, _original), do: {:error, :missing_uri_scheme}

  defp normalize_parsed(%URI{scheme: "file", host: host, path: path}, original) do
    cond do
      host not in [nil, ""] ->
        {:error, {:invalid_file_uri_host, host}}

      path in [nil, ""] ->
        {:error, {:invalid_file_uri_path, original}}

      true ->
        path |> URI.decode() |> file()
    end
  end

  defp normalize_parsed(%URI{scheme: scheme} = uri, _original) when scheme in ["http", "https"] do
    url(uri, :exact)
  end

  defp normalize_parsed(%URI{scheme: "pkg", path: path}, original) do
    with {:ok, path} <- non_empty(path, {:invalid_package_uri, original}) do
      {:ok, "pkg:#{encode_purl_path(path)}"}
    end
  end

  defp normalize_parsed(%URI{scheme: "allbert"} = uri, original),
    do: normalize_hierarchical(uri, original)

  defp normalize_parsed(%URI{scheme: "skill"} = uri, original),
    do: normalize_hierarchical(uri, original)

  defp normalize_parsed(%URI{scheme: "mcp"} = uri, original), do: normalize_mcp(uri, original)

  defp normalize_parsed(%URI{scheme: scheme} = uri, original)
       when scheme in @unsupported_schemes,
       do: normalize_hierarchical(uri, original)

  defp normalize_parsed(%URI{scheme: scheme}, _original),
    do: {:error, {:unsupported_resource_uri_scheme, scheme}}

  defp normalize_hierarchical(%URI{scheme: scheme, host: host} = uri, original) do
    with {:ok, host} <- non_empty(host, {:invalid_resource_uri, original}) do
      path = uri.path || "/"
      query = query_text(uri.query)
      {:ok, "#{String.downcase(scheme)}://#{String.downcase(host)}#{path}#{query}"}
    end
  end

  defp derive(%URI{scheme: "file"}, resource_uri) do
    with {:ok, path} <- path_from_file_uri(resource_uri) do
      {:ok, %{origin_kind: :local_path, canonical_id: path, unsupported?: false}}
    end
  end

  defp derive(%URI{scheme: scheme}, resource_uri) when scheme in ["http", "https"] do
    {:ok, %{origin_kind: :remote_url, canonical_id: resource_uri, unsupported?: false}}
  end

  defp derive(%URI{scheme: "allbert", host: "home", path: path}, _resource_uri) do
    {:ok,
     %{origin_kind: :allbert_home, canonical_id: URI.decode(path || "/"), unsupported?: false}}
  end

  defp derive(%URI{scheme: "allbert", host: "sources", path: path}, _resource_uri) do
    parts =
      path
      |> to_string()
      |> String.trim_leading("/")
      |> String.split("/", parts: 2)

    case parts do
      [_kind, id] when id != "" ->
        {:ok, %{origin_kind: :remote_source, canonical_id: URI.decode(id), unsupported?: false}}

      _other ->
        {:error, {:invalid_allbert_source_uri, path}}
    end
  end

  defp derive(%URI{scheme: "skill", host: skill_name, path: path}, _resource_uri) do
    script_path = path |> to_string() |> String.trim_leading("/") |> URI.decode()
    canonical_id = Enum.join(Enum.reject([skill_name, script_path], &(&1 in [nil, ""])), ":")
    {:ok, %{origin_kind: :local_skill_resource, canonical_id: canonical_id, unsupported?: false}}
  end

  defp derive(%URI{scheme: "pkg", path: path}, _resource_uri) do
    canonical_id =
      path
      |> to_string()
      |> String.split("/", parts: 2)
      |> Enum.map(&URI.decode/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(":")

    {:ok, %{origin_kind: :package_registry, canonical_id: canonical_id, unsupported?: false}}
  end

  defp derive(%URI{scheme: "mcp", host: server_id, path: path}, resource_uri) do
    server_resource_uri =
      path
      |> to_string()
      |> String.trim_leading("/")
      |> URI.decode()

    {:ok,
     %{
       origin_kind: :mcp_resource,
       canonical_id: resource_uri,
       unsupported?: false,
       server_id: server_id,
       server_resource_uri: server_resource_uri
     }}
  end

  defp derive(%URI{scheme: scheme}, resource_uri) when scheme in ["agent", "agent+https"],
    do: {:ok, %{origin_kind: :agent_endpoint, canonical_id: resource_uri, unsupported?: true}}

  defp derive(%URI{scheme: scheme}, _resource_uri),
    do: {:error, {:unsupported_resource_uri_scheme, scheme}}

  defp canonical_path(value) do
    value
    |> to_string()
    |> Path.expand()
    |> resolve_symlink_path(0)
  end

  defp resolve_symlink_path(path, depth) when depth > 40, do: Path.expand(path)

  defp resolve_symlink_path(path, depth) do
    case Path.split(path) do
      ["/" | parts] -> resolve_symlink_parts(parts, "/", depth)
      parts -> resolve_symlink_parts(parts, Path.expand("."), depth)
    end
  end

  defp resolve_symlink_parts([], path, _depth), do: path

  defp resolve_symlink_parts([part | rest], base, depth) do
    candidate = Path.join(base, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target
        |> expand_symlink_target(base)
        |> append_path_parts(rest)
        |> resolve_symlink_path(depth + 1)

      {:error, :enoent} ->
        append_path_parts(candidate, rest)

      {:error, _reason} ->
        resolve_symlink_parts(rest, candidate, depth)
    end
  end

  defp expand_symlink_target(target, base) do
    if Path.type(target) == :absolute do
      Path.expand(target)
    else
      Path.expand(target, base)
    end
  end

  defp append_path_parts(path, parts) do
    Enum.reduce(parts, path, fn part, acc -> Path.join(acc, part) end)
  end

  defp port_text(%URI{scheme: "http", port: port}) when port in [nil, 80], do: ""
  defp port_text(%URI{scheme: "https", port: port}) when port in [nil, 443], do: ""
  defp port_text(%URI{port: nil}), do: ""
  defp port_text(%URI{port: port}), do: ":#{port}"

  defp query_text(nil), do: ""
  defp query_text(""), do: ""
  defp query_text(query), do: "?#{query}"

  defp segment(value, error), do: value |> non_empty(error) |> encode_ok(&encode_segment/1)
  defp non_empty(nil, error), do: {:error, error}

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim()
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp normalize_mcp(%URI{host: host, path: path}, original) do
    with {:ok, server_id} <- mcp_server_id(host),
         {:ok, path} <- non_empty(path, {:invalid_mcp_uri, original}) do
      encoded =
        path
        |> String.trim_leading("/")
        |> URI.decode()
        |> encode_segment()

      {:ok, "mcp://#{server_id}/#{encoded}"}
    end
  end

  defp mcp_server_id(value) do
    with {:ok, value} <- non_empty(value, :missing_mcp_server_id) do
      if Regex.match?(~r/^[A-Za-z0-9_-]+$/, value) do
        {:ok, value}
      else
        {:error, {:invalid_mcp_server_id, value}}
      end
    end
  end

  defp encode_ok({:ok, value}, fun), do: {:ok, fun.(value)}
  defp encode_ok(error, _fun), do: error

  defp encode_segment(value), do: URI.encode(value, &segment_char?/1)
  defp encode_path(value), do: URI.encode(value, &path_char?/1)
  defp encode_purl_path(value), do: URI.encode(value, &purl_char?/1)

  defp segment_char?(char), do: path_char?(char) and char != ?/

  defp path_char?(char)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in [?-, ?., ?_, ?~, ?/, ?:],
       do: true

  defp path_char?(_char), do: false

  defp purl_char?(char)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or
              char in [?-, ?., ?_, ?~, ?/, ?:, ?@],
       do: true

  defp purl_char?(_char), do: false

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, inspect(reason))

  defp scheme(value) when is_binary(value), do: value |> URI.parse() |> Map.get(:scheme)
  defp scheme(_value), do: nil
end
