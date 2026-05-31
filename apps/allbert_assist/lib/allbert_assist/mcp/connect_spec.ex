defmodule AllbertAssist.Mcp.ConnectSpec do
  @moduledoc """
  Builds a settings-ready MCP server config from inert registry metadata.
  """

  alias AllbertAssist.Tools.Discovery

  @id_pattern ~r/[^a-z0-9_]+/
  @credential_query_names ~w(token api_key key secret password bearer access_token auth)

  defstruct [
    :candidate_id,
    :server_id,
    :transport,
    :manifest,
    :endpoint_fingerprint,
    :tool_definition_hash,
    command: nil,
    args: [],
    env: %{},
    base_url: nil,
    headers: %{},
    auth_ref: nil,
    confirmation: "required",
    required_secret_refs: [],
    exact_command: nil,
    exact_url: nil
  ]

  @type t :: %__MODULE__{}

  @doc "Build a connect spec from a persisted discovery candidate and manifest."
  def build(candidate, manifest, opts \\ %{})

  def build(candidate, manifest, opts) when is_map(manifest) and is_map(opts) do
    candidate_id = Map.fetch!(candidate, :id)
    server_id = server_id(opts, candidate, manifest)

    with {:ok, transport_spec} <- transport_spec(manifest, server_id) do
      spec =
        struct!(
          __MODULE__,
          transport_spec
          |> Map.merge(%{
            candidate_id: candidate_id,
            server_id: server_id,
            manifest: manifest,
            tool_definition_hash: tool_definition_hash(manifest),
            endpoint_fingerprint: endpoint_fingerprint(transport_spec)
          })
        )

      {:ok, spec}
    end
  end

  def build(_candidate, _manifest, _opts), do: {:error, :invalid_connect_spec}

  @doc "Return Settings Central key/value writes for the approved connection."
  def settings_writes(%__MODULE__{} = spec, enable_on_connect?) do
    [
      {"mcp.servers.#{spec.server_id}.enabled", false},
      {"mcp.servers.#{spec.server_id}.transport", Atom.to_string(spec.transport)},
      {"mcp.servers.#{spec.server_id}.confirmation", spec.confirmation},
      {"mcp.servers.#{spec.server_id}.tool_allowlist", []},
      {"mcp.servers.#{spec.server_id}.tool_denylist", []}
    ]
    |> Kernel.++(transport_writes(spec))
    |> Kernel.++([{"mcp.servers.#{spec.server_id}.enabled", enable_on_connect? == true}])
  end

  @doc "Trace-safe but exact operator consent summary."
  def consent_summary(%__MODULE__{} = spec, evaluation_report) do
    %{
      candidate_id: spec.candidate_id,
      server_id: spec.server_id,
      transport: spec.transport,
      exact_command: spec.exact_command,
      exact_url: spec.exact_url,
      required_secret_refs: spec.required_secret_refs,
      evaluation_report: evaluation_report,
      manifest_definition_hash: spec.tool_definition_hash,
      tool_definition_hash: spec.tool_definition_hash,
      endpoint_fingerprint: spec.endpoint_fingerprint,
      metadata_authority: "descriptive_metadata_only"
    }
    |> drop_nil_values()
  end

  def to_map(%__MODULE__{} = spec) do
    %{
      candidate_id: spec.candidate_id,
      server_id: spec.server_id,
      transport: spec.transport,
      command: spec.command,
      args: spec.args,
      env: spec.env,
      base_url: spec.base_url,
      headers: spec.headers,
      auth_ref: spec.auth_ref,
      confirmation: spec.confirmation,
      required_secret_refs: spec.required_secret_refs,
      endpoint_fingerprint: spec.endpoint_fingerprint,
      manifest_definition_hash: spec.tool_definition_hash,
      tool_definition_hash: spec.tool_definition_hash
    }
    |> drop_nil_values()
  end

  defp transport_writes(%__MODULE__{transport: :stdio} = spec) do
    [
      {"mcp.servers.#{spec.server_id}.command", spec.command},
      {"mcp.servers.#{spec.server_id}.args", spec.args},
      {"mcp.servers.#{spec.server_id}.env", spec.env}
    ]
  end

  defp transport_writes(%__MODULE__{transport: transport} = spec)
       when transport in [:sse, :streamable_http] do
    [
      {"mcp.servers.#{spec.server_id}.base_url", spec.base_url},
      {"mcp.servers.#{spec.server_id}.headers", spec.headers}
    ]
    |> maybe_put_auth_ref(spec)
  end

  defp maybe_put_auth_ref(writes, %__MODULE__{server_id: server_id, auth_ref: auth_ref})
       when is_binary(auth_ref) do
    writes ++ [{"mcp.servers.#{server_id}.auth_ref", auth_ref}]
  end

  defp maybe_put_auth_ref(writes, _spec), do: writes

  defp transport_spec(manifest, server_id) do
    cond do
      remote = first_remote(manifest) ->
        remote_transport_spec(remote, server_id)

      package = first_package(manifest) ->
        package_transport_spec(package, server_id)

      true ->
        {:error, :missing_transport}
    end
  end

  defp remote_transport_spec(remote, server_id) do
    transport =
      normalize_transport(get_any(remote, ["transport", :transport]) || "streamable_http")

    base_url = get_any(remote, ["url_direct", :url_direct, "direct_url", :direct_url])
    auth_method = get_any(remote, ["authentication_method", :authentication_method])

    cond do
      transport not in [:sse, :streamable_http] ->
        {:error, {:unsupported_transport, transport}}

      true ->
        with :ok <- validate_remote_url(base_url) do
          {auth_ref, required_secret_refs} = auth_ref(auth_method, server_id)

          {:ok,
           %{
             transport: transport,
             base_url: base_url,
             auth_ref: auth_ref,
             required_secret_refs: required_secret_refs,
             exact_url: base_url
           }}
        end
    end
  end

  defp package_transport_spec(package, server_id) do
    transport = get_any(package, ["transport", :transport]) || %{}
    type = normalize_transport(get_any(transport, ["type", :type]) || "stdio")

    case type do
      :stdio -> stdio_spec(package, transport, server_id)
      :sse -> http_spec(type, package, transport, server_id)
      :streamable_http -> http_spec(type, package, transport, server_id)
      other -> {:error, {:unsupported_transport, other}}
    end
  end

  defp stdio_spec(package, transport, server_id) do
    command = get_any(transport, ["command", :command]) || get_any(package, ["command", :command])
    args = get_any(transport, ["args", :args]) || get_any(package, ["args", :args])
    {command, args} = package_command(command, args, package)
    {env, required_secret_refs} = environment_secret_refs(package, server_id)

    if is_binary(command) and command != "" do
      args = Enum.map(args, &to_string/1)

      {:ok,
       %{
         transport: :stdio,
         command: command,
         args: args,
         env: env,
         required_secret_refs: required_secret_refs,
         exact_command: %{command: command, args: args}
       }}
    else
      {:error, :missing_stdio_command}
    end
  end

  defp http_spec(type, package, transport, server_id) do
    base_url =
      get_any(transport, [
        "url",
        :url,
        "endpoint",
        :endpoint,
        "base_url",
        :base_url,
        "baseUrl",
        :baseUrl
      ])

    auth_method = get_any(package, ["authentication_method", :authentication_method])

    if valid_url?(base_url) do
      {auth_ref, required_secret_refs} = auth_ref(auth_method, server_id)

      with :ok <- validate_remote_url(base_url) do
        {:ok,
         %{
           transport: type,
           base_url: base_url,
           auth_ref: auth_ref,
           required_secret_refs: required_secret_refs,
           exact_url: base_url
         }}
      end
    else
      {:error, :missing_remote_url}
    end
  end

  defp package_command(command, args, _package) when is_binary(command) and is_list(args) do
    {command, args}
  end

  defp package_command(command, _args, _package) when is_binary(command), do: {command, []}

  defp package_command(_command, _args, package) do
    registry_type =
      get_any(package, ["registryType", :registryType, "registry_type", :registry_type])

    identifier = get_any(package, ["identifier", :identifier])
    version = get_any(package, ["version", :version])

    case {registry_type, identifier} do
      {"npm", identifier} when is_binary(identifier) ->
        {"npx", ["-y", package_identifier(identifier, version)]}

      {"pypi", identifier} when is_binary(identifier) ->
        {"uvx", [package_identifier(identifier, version)]}

      _other ->
        {nil, []}
    end
  end

  defp package_identifier(identifier, version) when is_binary(version) and version != "" do
    "#{identifier}@#{version}"
  end

  defp package_identifier(identifier, _version), do: identifier

  defp environment_secret_refs(package, server_id) do
    package
    |> get_any([
      "environmentVariables",
      :environmentVariables,
      "environment_variables",
      :environment_variables
    ])
    |> list_value()
    |> Enum.reduce({%{}, []}, fn env_var, {env, refs} ->
      name = get_any(env_var, ["name", :name])
      required? = truthy?(get_any(env_var, ["isRequired", :isRequired, "required", :required]))
      secret? = truthy?(get_any(env_var, ["isSecret", :isSecret, "secret", :secret]))

      if is_binary(name) and name != "" and (required? or secret?) do
        ref = "secret://mcp/#{server_id}/#{String.downcase(name)}"
        {Map.put(env, name, ref), [%{name: name, ref: ref, required?: required?} | refs]}
      else
        {env, refs}
      end
    end)
    |> then(fn {env, refs} -> {env, Enum.reverse(refs)} end)
  end

  defp auth_ref(method, server_id) when method in ["api_key", :api_key, "bearer", :bearer] do
    ref = "secret://mcp/#{server_id}/auth"
    {ref, [%{name: "auth", ref: ref, required?: true}]}
  end

  defp auth_ref(_method, _server_id), do: {nil, []}

  defp first_remote(manifest) do
    manifest
    |> get_any(["remotes", :remotes])
    |> list_value()
    |> Enum.find(fn remote ->
      valid_url?(get_any(remote, ["url_direct", :url_direct, "direct_url", :direct_url]))
    end)
  end

  defp first_package(manifest) do
    manifest
    |> get_any(["packages", :packages])
    |> list_value()
    |> List.first()
  end

  defp endpoint_fingerprint(%{transport: :stdio, command: command, args: args}) do
    "stdio:#{Enum.join([command | args], " ")}"
  end

  defp endpoint_fingerprint(%{base_url: base_url}), do: "url:#{base_url}"

  defp tool_definition_hash(manifest) do
    manifest
    |> get_any(["tools", :tools])
    |> list_value()
    |> Discovery.tool_list_hash()
  end

  defp server_id(opts, candidate, manifest) do
    opts
    |> Map.get(:server_id, Map.get(opts, "server_id"))
    |> case do
      value when is_binary(value) and value != "" ->
        slug(value)

      _value ->
        candidate
        |> Map.get(:remote_server_id)
        |> Kernel.||(Map.get(candidate, :name))
        |> Kernel.||(get_any(manifest, ["name", :name]))
        |> Kernel.||("mcp_server")
        |> slug()
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(@id_pattern, "_")
    |> String.trim("_")
    |> case do
      "" -> "mcp_server"
      slug -> String.slice(slug, 0, 80)
    end
  end

  defp normalize_transport("streamable-http"), do: :streamable_http
  defp normalize_transport("streamable_http"), do: :streamable_http
  defp normalize_transport(:streamable_http), do: :streamable_http
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport(:sse), do: :sse
  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport(:stdio), do: :stdio
  defp normalize_transport(value), do: value

  defp valid_url?(value) when is_binary(value) do
    String.starts_with?(value, ["http://", "https://"])
  end

  defp valid_url?(_value), do: false

  defp validate_remote_url(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      not valid_url?(value) ->
        {:error, :missing_remote_url}

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        {:error, {:credentialed_remote_url, :userinfo}}

      credential_query = credential_query_param(uri.query) ->
        {:error, {:credentialed_remote_url, {:query_param, credential_query}}}

      opaque_query = opaque_query_param(uri.query) ->
        {:error, {:credentialed_remote_url, {:opaque_query_param, opaque_query}}}

      true ->
        :ok
    end
  end

  defp validate_remote_url(_value), do: {:error, :missing_remote_url}

  defp credential_query_param(nil), do: nil

  defp credential_query_param(query) do
    query
    |> URI.query_decoder()
    |> Enum.find_value(fn {key, _value} ->
      normalized =
        key
        |> to_string()
        |> String.downcase()

      if normalized in @credential_query_names, do: normalized
    end)
  end

  defp opaque_query_param(nil), do: nil

  defp opaque_query_param(query) do
    query
    |> URI.query_decoder()
    |> Enum.find_value(fn {key, value} ->
      if opaque_secret_like?(value), do: to_string(key)
    end)
  end

  defp opaque_secret_like?(value) when is_binary(value) do
    byte_size(value) >= 32 and String.match?(value, ~r/^[A-Za-z0-9_\-.~+\/=]+$/)
  end

  defp opaque_secret_like?(_value), do: false

  defp get_any(nil, _keys), do: nil

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_value, _keys), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
end
