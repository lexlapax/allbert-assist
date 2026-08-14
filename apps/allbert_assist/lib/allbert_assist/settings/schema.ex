defmodule AllbertAssist.Settings.Schema do
  alias AllbertAssist.Pack.Residual
  alias AllbertAssist.Settings.FragmentOwner

  @moduledoc """
  Settings Central schema compatibility facade.

  v0.31 M8 assembles schema, defaults, and safe-write keys from registered
  `AllbertAssist.Settings.Fragment` owners while preserving the pre-M8 public
  API for callers.
  """

  require Logger

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.ModelCapabilities
  alias AllbertAssist.Settings.ModelRoles
  alias AllbertAssist.Settings.ProviderCatalog

  # Dynamic entries remain a Settings Central validation concern. Fragment
  # owners supply the wildcard declarations and defaults; these field schemas
  # validate concrete provider/profile/server/client instances at runtime.
  @provider_schema %{
    "type" => %{
      type: :enum,
      allowed_values: [
        "openai",
        "openai_compatible",
        "anthropic",
        "openrouter",
        "google",
        "fake_voice",
        "fake_media",
        "local"
      ]
    },
    "enabled" => %{type: :boolean},
    "endpoint_kind" => %{
      type: :enum,
      allowed_values: ["credentialed_remote", "local_endpoint"]
    },
    "base_url" => %{type: :url_or_nil},
    "api_key_ref" => %{type: :secret_ref_or_nil}
  }

  @model_profile_schema %{
    "provider" => %{type: :provider_ref},
    "model" => %{type: :string},
    "aliases" => %{type: :string_list},
    "capabilities" => %{type: :model_capabilities},
    "media" => %{type: :model_media},
    "temperature" => %{type: :temperature},
    "max_tokens" => %{type: :positive_integer},
    "timeout_ms" => %{type: :timeout_ms}
  }

  @mcp_server_schema %{
    "enabled" => %{type: :boolean},
    "transport" => %{type: :enum, allowed_values: ["stdio", "sse", "streamable_http"]},
    "command" => %{type: :string},
    "args" => %{type: :string_list},
    "env" => %{type: :mcp_secret_ref_string_map},
    "base_url" => %{type: :url_or_nil},
    "headers" => %{type: :mcp_secret_ref_string_map},
    "auth_ref" => %{type: :mcp_secret_ref_or_nil},
    "tool_allowlist" => %{type: :string_list},
    "tool_denylist" => %{type: :string_list},
    "confirmation" => %{type: :enum, allowed_values: ["required", "denied"]}
  }

  @public_protocol_client_schema %{
    "enabled" => %{type: :boolean},
    "token_ref" => %{type: :public_protocol_secret_ref},
    "rate_limit.limit" => %{type: :bounded_integer, min: 1, max: 10_000},
    "rate_limit.period_ms" => %{type: :bounded_integer, min: 100, max: 86_400_000},
    "rate_limit.burst" => %{type: :bounded_integer, min: 0, max: 10_000}
  }

  @resource_grant_required_keys ~w[
    id
    resource_uri
    origin_kind
    scope
    operation_class
    access_mode
    created_at
  ]

  @resource_grant_allowed_keys ~w[
    id
    resource_uri
    origin_kind
    scope
    operation_class
    access_mode
    downstream_consumer
    action_permission
    origin_channel
    resolver_channel
    created_at
    expires_at
    revoked_at
    audit_path
    reason
    metadata
  ]

  @resource_grant_atom_keys Map.new(@resource_grant_allowed_keys, &{&1, String.to_atom(&1)})

  def defaults, do: Fragments.defaults()

  def runtime_schema, do: schema()

  def schema, do: Fragments.schema()

  def safe_write_keys, do: Fragments.safe_write_keys()

  @doc false
  def core_schema,
    do:
      FragmentOwner.schema!(
        "allbert_assist",
        :allbert_assist,
        Residual.settings_fragments()
      )

  @doc false
  def core_defaults,
    do:
      FragmentOwner.defaults!(
        "allbert_assist",
        :allbert_assist,
        Residual.settings_fragments()
      )

  @doc false
  def core_safe_write_keys,
    do:
      FragmentOwner.safe_write_keys!(
        "allbert_assist",
        :allbert_assist,
        Residual.settings_fragments()
      )

  def safe_write_key?(key) when is_binary(key) do
    Enum.any?(safe_write_keys(), &key_matches?(&1, key))
  end

  def safe_write_key?(_key), do: false

  def validate_key_value(key, value, settings \\ defaults()) when is_binary(key) do
    cond do
      not known_key?(key) ->
        {:error, {:unknown_setting, key}}

      not safe_write_key?(key) ->
        {:error, {:read_only_setting, key}}

      true ->
        validate_known_key_value(key, value, settings)
    end
  end

  def validate_settings(settings, opts \\ [])

  def validate_settings(settings, _opts) when is_map(settings) do
    with :ok <- reject_unknown_top_level(settings),
         :ok <- validate_static_keys(settings),
         :ok <- validate_providers(settings),
         :ok <- validate_model_profiles(settings),
         :ok <- validate_model_roles(settings),
         :ok <- validate_model_preferences(settings),
         :ok <- validate_mcp(settings),
         :ok <- validate_public_protocol(settings),
         :ok <- validate_surface_policy(settings),
         :ok <- validate_runtime_refs(settings),
         :ok <- validate_dynamic_codegen(settings),
         :ok <- validate_templates(settings),
         :ok <- validate_channels(settings) do
      :ok
    end
  end

  def validate_settings(_settings, _opts), do: {:error, {:invalid_settings, :not_a_map}}

  def get_dotted(settings, key) do
    key
    |> split_key()
    |> Enum.reduce_while(settings, fn segment, acc ->
      case acc do
        %{^segment => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
  end

  def put_dotted(settings, key, value) do
    put_in_segments(settings, split_key(key), value)
  end

  def known_key?(key) do
    Map.has_key?(schema(), key) ||
      wildcard_known_key?(key) ||
      default_key?(key)
  end

  def sensitive_key?(key) do
    if public_protocol_settings_key?(key) do
      false
    else
      key
      |> String.split(~r/[._-]/, trim: true)
      |> Enum.any?(
        &(&1 in ["secret", "token", "password", "api", "key", "private", "credential"])
      )
    end
  end

  @doc "Return additive schema metadata for one concrete setting key."
  def setting_metadata(key) when is_binary(key) do
    case Map.get(schema(), key) do
      nil -> if wildcard_known_key?(key), do: schema_for_key(key) || %{}, else: %{}
      metadata -> metadata
    end
  end

  def setting_metadata(_key), do: %{}

  defp public_protocol_settings_key?(key) when is_binary(key) do
    String.starts_with?(key, "openai_api.") or
      String.starts_with?(key, "mcp_server.") or
      String.starts_with?(key, "acp_server.") or
      String.starts_with?(key, "public_protocol.")
  end

  defp public_protocol_settings_key?(_key), do: false

  defp validate_known_key_value(key, value, settings) do
    with :ok <- validate_value(schema_for_key(key), value, key, settings),
         :ok <- validate_closed_task_write(key, value),
         :ok <- validate_text_task_write_capability(key, value, settings) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_setting, key, reason}}
    end
  end

  defp validate_closed_task_write("model_preferences.tasks.fanout_manager", []),
    do: {:error, :fanout_manager_profiles_required}

  defp validate_closed_task_write("model_preferences.tasks.fanout_synthesis", []),
    do: {:error, :fanout_synthesis_profiles_required}

  defp validate_closed_task_write(_key, _value), do: :ok

  defp validate_text_task_write_capability(
         "model_preferences.tasks.direct_answer",
         profiles,
         settings
       ),
       do: validate_text_generation_profiles(profiles, settings)

  defp validate_text_task_write_capability(
         "model_preferences.tasks.fanout_manager",
         profiles,
         settings
       ),
       do: validate_text_generation_profiles(profiles, settings)

  defp validate_text_task_write_capability(
         "model_preferences.tasks.fanout_synthesis",
         profiles,
         settings
       ),
       do: validate_text_generation_profiles(profiles, settings)

  defp validate_text_task_write_capability(
         "intent.direct_answer_model_profile",
         profile,
         settings
       ),
       do: validate_text_generation_profiles([profile], settings)

  defp validate_text_task_write_capability(_key, _value, _settings), do: :ok

  defp validate_text_generation_profiles(profiles, settings) do
    Enum.reduce_while(profiles, :ok, fn profile, :ok ->
      model_profile = get_in(settings, ["model_profiles", profile]) || %{}

      if ModelRoles.reference?(profile) or
           ModelCapabilities.runtime_text_generation?(model_profile) do
        {:cont, :ok}
      else
        {:halt, {:error, {:profile_missing_capability, profile, "text_generation"}}}
      end
    end)
  end

  defp schema_for_key(key) do
    Map.get(schema(), key) || schema_for_dynamic_key(key)
  end

  defp schema_for_dynamic_key(key) do
    cond do
      Regex.match?(~r/^providers\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@provider_schema, &1))

      Regex.match?(~r/^model_profiles\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@model_profile_schema, &1))

      Regex.match?(~r/^model_preferences\.tasks\.[^.]+$/, key) ->
        %{type: :task_profile_ref_list}

      Regex.match?(~r/^model_preferences\.capabilities\.[^.]+$/, key) ->
        %{type: :profile_ref_list}

      Regex.match?(~r/^mcp\.servers\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@mcp_server_schema, &1))

      true ->
        schema_for_surface_key(key)
    end
  end

  defp schema_for_surface_key(key) do
    cond do
      public_protocol_client_key?(key) ->
        key
        |> public_protocol_client_field()
        |> then(&Map.fetch!(@public_protocol_client_schema, &1))

      surface_policy_key?(key) ->
        key
        |> surface_policy_field()
        |> surface_policy_schema()

      true ->
        nil
    end
  end

  defp validate_static_keys(settings) do
    schema()
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case validate_value(schema_for_key(key), get_dotted(settings, key), key, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_setting, key, reason}}}
      end
    end)
  end

  defp validate_providers(settings) do
    settings
    |> get_in(["providers"])
    |> case do
      providers when is_map(providers) ->
        validate_dynamic_map(providers, @provider_schema, "providers", settings)

      other ->
        {:error, {:invalid_setting, "providers", {:expected_map, other}}}
    end
  end

  defp validate_model_profiles(settings) do
    settings
    |> get_in(["model_profiles"])
    |> case do
      profiles when is_map(profiles) ->
        with :ok <-
               validate_dynamic_map(profiles, @model_profile_schema, "model_profiles", settings) do
          validate_model_profile_provider_constraints(profiles, settings)
        end

      other ->
        {:error, {:invalid_setting, "model_profiles", {:expected_map, other}}}
    end
  end

  defp validate_model_profile_provider_constraints(profiles, settings) do
    Enum.reduce_while(profiles, :ok, fn {name, attrs}, :ok ->
      case validate_model_profile_provider_constraint(name, attrs, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_model_profile_provider_constraint(name, attrs, settings) when is_map(attrs) do
    provider = Map.get(attrs, "provider")
    provider_type = get_in(settings, ["providers", provider, "type"])
    max_tokens = Map.get(attrs, "max_tokens")

    if provider_type == "openai" && is_integer(max_tokens) && max_tokens < 16 do
      {:error,
       {:invalid_setting, "model_profiles.#{name}.max_tokens", {:below_provider_minimum, 16}}}
    else
      :ok
    end
  end

  defp validate_model_profile_provider_constraint(_name, _attrs, _settings), do: :ok

  defp validate_model_roles(settings) do
    case get_in(settings, ["model_roles"]) do
      %{
        "schema_version" => 1,
        "fast" => %{"profile" => _fast},
        "capable" => %{"profile" => _capable},
        "thinking" => %{"profile" => _thinking}
      } = roles ->
        expected_keys = ~w[capable fast schema_version thinking]

        with true <- Enum.sort(Map.keys(roles)) == expected_keys,
             true <- Enum.all?(ModelRoles.roles(), &(Map.keys(roles[&1]) == ["profile"])) do
          :ok
        else
          _invalid -> {:error, {:invalid_setting, "model_roles", :invalid_shape}}
        end

      other ->
        {:error, {:invalid_setting, "model_roles", {:expected_role_map, other}}}
    end
  end

  defp validate_model_preferences(settings) do
    case get_in(settings, ["model_preferences"]) do
      preferences when is_map(preferences) ->
        with :ok <- validate_model_preference_keys(preferences),
             :ok <-
               validate_model_preference_map(
                 get_in(preferences, ["tasks"]),
                 "model_preferences.tasks",
                 :task,
                 settings
               ) do
          validate_model_preference_map(
            get_in(preferences, ["capabilities"]),
            "model_preferences.capabilities",
            :capability,
            settings
          )
        end

      other ->
        {:error, {:invalid_setting, "model_preferences", {:expected_map, other}}}
    end
  end

  defp validate_model_preference_keys(preferences) do
    allowed = ~w[schema_version primary tasks capabilities]

    preferences
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_setting, "model_preferences.#{key}"}}
    end
  end

  defp validate_model_preference_map(preferences, prefix, kind, settings)
       when is_map(preferences) do
    Enum.reduce_while(preferences, :ok, fn {name, profiles}, :ok ->
      key = "#{prefix}.#{name}"

      with :ok <- validate_model_preference_name(name, key, kind),
           :ok <- validate_value(model_preference_schema(kind), profiles, key, settings),
           :ok <- validate_model_task_contract(kind, name, profiles, settings) do
        {:cont, :ok}
      else
        {:error, {:invalid_setting, _key, _reason} = reason} ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_setting, key, reason}}}
      end
    end)
  end

  defp validate_model_preference_map(other, prefix, _kind, _settings),
    do: {:error, {:invalid_setting, prefix, {:expected_map, other}}}

  defp model_preference_schema(:task), do: %{type: :task_profile_ref_list}
  defp model_preference_schema(:capability), do: %{type: :profile_ref_list}

  defp validate_model_task_contract(:task, "fanout_manager", [], _settings),
    do: {:error, :fanout_manager_profiles_required}

  defp validate_model_task_contract(:task, "fanout_synthesis", [], _settings),
    do: {:error, :fanout_synthesis_profiles_required}

  defp validate_model_task_contract(:task, "fanout_manager", profiles, settings),
    do: validate_text_generation_profiles(profiles, settings)

  defp validate_model_task_contract(:task, "fanout_synthesis", profiles, settings),
    do: validate_text_generation_profiles(profiles, settings)

  defp validate_model_task_contract(_kind, _name, _profiles, _settings), do: :ok

  defp validate_model_preference_name(name, key, :task) do
    if valid_name?(name), do: :ok, else: {:error, {:invalid_setting, key, :invalid_name}}
  end

  defp validate_model_preference_name(name, key, :capability) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_setting, key, :invalid_name}}

      name not in ProviderCatalog.known_capabilities() ->
        {:error, {:invalid_setting, key, {:unknown_capability, name}}}

      true ->
        :ok
    end
  end

  defp validate_mcp(settings) do
    with :ok <- validate_mcp_launchers(settings),
         :ok <-
           settings
           |> get_in(["mcp", "servers"])
           |> validate_mcp_servers(settings) do
      validate_mcp_discovery(settings)
    end
  end

  defp validate_mcp_servers(servers, settings) when is_map(servers) do
    with :ok <- validate_dynamic_map(servers, @mcp_server_schema, "mcp.servers", settings) do
      validate_mcp_server_constraints(servers, settings)
    end
  end

  defp validate_mcp_servers(other, _settings),
    do: {:error, {:invalid_setting, "mcp.servers", {:expected_map, other}}}

  defp validate_mcp_launchers(settings) do
    launchers = get_dotted(settings, "mcp.stdio.allowed_launchers") || []

    if Enum.all?(launchers, &safe_mcp_launcher?/1) do
      :ok
    else
      {:error, {:invalid_setting, "mcp.stdio.allowed_launchers", :unsafe_launcher}}
    end
  end

  defp validate_mcp_discovery(settings) do
    with :ok <- validate_mcp_discovery_auto_connect(settings) do
      validate_mcp_discovery_pulsemcp(settings)
    end
  end

  defp validate_mcp_discovery_auto_connect(settings) do
    case get_dotted(settings, "mcp.discovery.auto_connect") do
      false ->
        :ok

      value ->
        {:error, {:invalid_setting, "mcp.discovery.auto_connect", {:must_remain_false, value}}}
    end
  end

  defp validate_mcp_discovery_pulsemcp(settings) do
    enabled? = get_dotted(settings, "mcp.discovery.sources.pulsemcp.enabled")
    api_key_ref = get_dotted(settings, "mcp.discovery.sources.pulsemcp.api_key_ref")
    tenant_ref = get_dotted(settings, "mcp.discovery.sources.pulsemcp.tenant_ref")

    cond do
      enabled? != true ->
        :ok

      not is_binary(api_key_ref) ->
        {:error,
         {:invalid_setting, "mcp.discovery.sources.pulsemcp.api_key_ref",
          {:required_when_enabled, api_key_ref}}}

      not is_binary(tenant_ref) ->
        {:error,
         {:invalid_setting, "mcp.discovery.sources.pulsemcp.tenant_ref",
          {:required_when_enabled, tenant_ref}}}

      true ->
        :ok
    end
  end

  defp validate_mcp_server_constraints(servers, settings) do
    Enum.reduce_while(servers, :ok, fn {name, attrs}, :ok ->
      case validate_mcp_server_constraint(name, attrs, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_mcp_server_constraint(_name, %{"enabled" => true} = attrs, settings) do
    case Map.get(attrs, "transport") do
      "stdio" -> validate_enabled_stdio_mcp_server(attrs, settings)
      "sse" -> validate_enabled_http_mcp_server(attrs)
      "streamable_http" -> validate_enabled_http_mcp_server(attrs)
      other -> {:error, {:invalid_setting, "mcp.servers.*.transport", {:required, other}}}
    end
  end

  defp validate_mcp_server_constraint(_name, attrs, _settings) when is_map(attrs) do
    validate_disabled_mcp_server_branches(attrs)
  end

  defp validate_mcp_server_constraint(name, _attrs, _settings),
    do: {:error, {:invalid_setting, "mcp.servers.#{name}", :expected_map}}

  defp validate_public_protocol(settings) do
    with :ok <- validate_public_surface_clients(settings, "mcp_server", "mcp_http"),
         :ok <- validate_public_surface_clients(settings, "openai_api", "openai_api") do
      :ok
    end
  end

  defp validate_public_surface_clients(settings, namespace, surface) do
    clients = get_dotted(settings, "#{namespace}.clients") || %{}

    case validate_public_protocol_clients(clients, surface) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_setting, "#{namespace}.clients", reason}}
    end
  end

  defp validate_enabled_stdio_mcp_server(attrs, settings) do
    with :ok <- require_mcp_string(attrs, "command"),
         :ok <- validate_stdio_launcher_allowed(Map.fetch!(attrs, "command"), settings),
         :ok <- forbid_mcp_field(attrs, "base_url"),
         :ok <- forbid_mcp_field(attrs, "headers") do
      :ok
    end
  end

  defp validate_enabled_http_mcp_server(attrs) do
    with :ok <- require_mcp_string(attrs, "base_url"),
         :ok <- forbid_mcp_field(attrs, "command"),
         :ok <- forbid_mcp_field(attrs, "args"),
         :ok <- forbid_mcp_field(attrs, "env") do
      :ok
    end
  end

  defp validate_disabled_mcp_server_branches(%{"transport" => "stdio"} = attrs) do
    with :ok <- forbid_mcp_field(attrs, "base_url") do
      forbid_mcp_field(attrs, "headers")
    end
  end

  defp validate_disabled_mcp_server_branches(%{"transport" => transport} = attrs)
       when transport in ["sse", "streamable_http"] do
    with :ok <- forbid_mcp_field(attrs, "command"),
         :ok <- forbid_mcp_field(attrs, "args") do
      forbid_mcp_field(attrs, "env")
    end
  end

  defp validate_disabled_mcp_server_branches(_attrs), do: :ok

  defp require_mcp_string(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, {:invalid_setting, "mcp.servers.*.#{field}", {:required, value}}}
    end
  end

  defp forbid_mcp_field(attrs, field) do
    case Map.get(attrs, field) do
      nil -> :ok
      [] -> :ok
      value -> {:error, {:invalid_setting, "mcp.servers.*.#{field}", {:forbidden, value}}}
    end
  end

  defp validate_stdio_launcher_allowed(command, settings) do
    allowed = get_dotted(settings, "mcp.stdio.allowed_launchers") || []

    if command in allowed do
      :ok
    else
      {:error, {:invalid_setting, "mcp.servers.*.command", {:launcher_not_allowed, command}}}
    end
  end

  defp validate_dynamic_map(items, field_schema, prefix, settings) do
    Enum.reduce_while(items, :ok, &validate_dynamic_item(&1, &2, field_schema, prefix, settings))
  end

  defp validate_dynamic_item({name, attrs}, :ok, field_schema, prefix, settings) do
    dynamic_prefix = "#{prefix}.#{name}"

    with :ok <- validate_dynamic_name(name, dynamic_prefix),
         :ok <- validate_dynamic_map_attrs(attrs, dynamic_prefix),
         :ok <- validate_dynamic_attrs(attrs, field_schema, dynamic_prefix, settings) do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_dynamic_name(name, prefix) do
    if valid_name?(name), do: :ok, else: {:error, {:invalid_setting, prefix, :invalid_name}}
  end

  defp validate_dynamic_map_attrs(attrs, prefix) do
    if is_map(attrs), do: :ok, else: {:error, {:invalid_setting, prefix, :expected_map}}
  end

  defp validate_dynamic_attrs(attrs, field_schema, prefix, settings) do
    Enum.reduce_while(attrs, :ok, &validate_dynamic_attr(&1, &2, field_schema, prefix, settings))
  end

  defp validate_dynamic_attr({field, value}, :ok, field_schema, prefix, settings) do
    key = "#{prefix}.#{field}"

    with {:ok, schema} <- fetch_dynamic_schema(field_schema, field, key),
         :ok <- validate_value(schema, value, key, settings) do
      {:cont, :ok}
    else
      {:error, {:unknown_setting, _key} = reason} -> {:halt, {:error, reason}}
      {:error, reason} -> {:halt, {:error, {:invalid_setting, key, reason}}}
    end
  end

  defp fetch_dynamic_schema(field_schema, field, key) do
    case Map.fetch(field_schema, field) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, {:unknown_setting, key}}
    end
  end

  defp validate_runtime_refs(settings) do
    alias_name = get_dotted(settings, "runtime.model_alias")

    if is_map(get_in(settings, ["model_profiles"])) &&
         Map.has_key?(settings["model_profiles"], alias_name) do
      :ok
    else
      {:error, {:invalid_setting, "runtime.model_alias", {:unknown_model_profile, alias_name}}}
    end
  end

  defp validate_value(%{type: :string}, value, _key, _settings) when is_binary(value) do
    if String.trim(value) == "" or String.length(value) > 200 do
      {:error, :invalid_string}
    else
      :ok
    end
  end

  defp validate_value(%{type: :string}, value, _key, _settings),
    do: {:error, {:expected_string, value}}

  defp validate_value(%{type: :loopback_http_base_url}, value, _key, _settings)
       when is_binary(value) do
    uri = value |> String.trim() |> URI.parse()

    case loopback_http_base_url_error(uri) do
      nil -> :ok
      reason -> {:error, {:expected_loopback_http_base_url, reason}}
    end
  end

  defp validate_value(%{type: :loopback_http_base_url}, value, _key, _settings),
    do: {:error, {:expected_loopback_http_base_url, value}}

  defp validate_value(%{type: :string_or_empty}, value, _key, _settings)
       when is_binary(value) do
    if String.length(value) <= 200, do: :ok, else: {:error, :invalid_string}
  end

  defp validate_value(%{type: :string_or_empty}, value, _key, _settings),
    do: {:error, {:expected_string, value}}

  defp validate_value(%{type: :loopback_bind_host}, value, _key, _settings)
       when is_binary(value) do
    if value in ["127.0.0.1", "localhost", "::1"] do
      :ok
    else
      {:error, {:expected_loopback_bind_host, value}}
    end
  end

  defp validate_value(%{type: :loopback_bind_host}, value, _key, _settings),
    do: {:error, {:expected_loopback_bind_host, value}}

  defp validate_value(%{type: :port_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :port_or_nil}, value, _key, _settings) when is_integer(value) do
    if value >= 1 and value <= 65_535, do: :ok, else: {:error, {:out_of_range, 1, 65_535}}
  end

  defp validate_value(%{type: :port_or_nil}, value, _key, _settings),
    do: {:error, {:expected_port_or_nil, value}}

  defp validate_value(%{type: :public_api_path_prefix}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^\/[A-Za-z0-9_\/-]*$/, value) and value == "/v1" do
      :ok
    else
      {:error, {:expected_public_api_path_prefix, "/v1"}}
    end
  end

  defp validate_value(%{type: :public_api_path_prefix}, value, _key, _settings),
    do: {:error, {:expected_public_api_path_prefix, value}}

  defp validate_value(%{type: :email_or_empty}, "", _key, _settings), do: :ok

  defp validate_value(%{type: :email_or_empty}, value, _key, _settings)
       when is_binary(value) do
    if valid_email?(value), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_value(%{type: :email_or_empty}, value, _key, _settings),
    do: {:error, {:expected_email, value}}

  defp validate_value(%{type: :timezone}, value, _key, _settings) when is_binary(value) do
    case DateTime.now(value) do
      {:ok, _datetime} -> :ok
      {:error, :utc_only_time_zone_database} -> validate_timezone_name(value)
      {:error, reason} -> {:error, {:invalid_timezone, reason}}
    end
  end

  defp validate_value(%{type: :timezone}, value, _key, _settings),
    do: {:error, {:expected_timezone, value}}

  defp validate_value(%{type: :enum, allowed_values: values}, value, _key, _settings) do
    if value in values, do: :ok, else: {:error, {:allowed_values, values}}
  end

  defp validate_value(%{type: :boolean}, value, _key, _settings) when is_boolean(value), do: :ok

  defp validate_value(%{type: :boolean}, value, _key, _settings),
    do: {:error, {:expected_boolean, value}}

  defp validate_value(%{type: :string_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :string_or_nil}, value, _key, _settings) when is_binary(value),
    do: :ok

  defp validate_value(%{type: :string_or_nil}, value, _key, _settings),
    do: {:error, {:expected_string_or_nil, value}}

  defp validate_value(%{type: :hex_secret_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :hex_secret_or_nil}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^[0-9a-fA-F]{64}$/, value) do
      :ok
    else
      {:error, :invalid_hex_secret}
    end
  end

  defp validate_value(%{type: :hex_secret_or_nil}, value, _key, _settings),
    do: {:error, {:expected_hex_secret_or_nil, value}}

  defp validate_value(%{type: :string_list}, value, _key, _settings) when is_list(value) do
    if Enum.all?(value, &valid_string_list_item?/1) do
      :ok
    else
      {:error, {:expected_string_list, value}}
    end
  end

  defp validate_value(%{type: :string_list}, value, _key, _settings),
    do: {:error, {:expected_string_list, value}}

  defp validate_value(%{type: :public_tool_list}, value, _key, _settings) when is_list(value) do
    case ExposureFilter.filter_tools(value) do
      {:ok, _tools} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_value(%{type: :public_tool_list}, value, _key, _settings),
    do: {:error, {:expected_public_tool_list, value}}

  defp validate_value(%{type: :public_memory_namespace_list}, value, _key, _settings)
       when is_list(value) do
    case ExposureFilter.filter_memory_namespaces(value) do
      {:ok, _namespaces} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_value(%{type: :public_memory_namespace_list}, value, _key, _settings),
    do: {:error, {:expected_public_memory_namespace_list, value}}

  defp validate_value(%{type: :public_protocol_clients, surface: surface}, value, _key, _settings)
       when is_map(value) do
    validate_public_protocol_clients(value, surface)
  end

  defp validate_value(%{type: :public_protocol_clients}, value, _key, _settings),
    do: {:error, {:expected_public_protocol_clients, value}}

  defp validate_value(%{type: :public_protocol_secret_ref}, value, _key, _settings)
       when is_binary(value) do
    if TokenAuth.public_protocol_secret_ref?(value) do
      :ok
    else
      {:error, :invalid_public_protocol_secret_ref}
    end
  end

  defp validate_value(%{type: :public_protocol_secret_ref}, value, _key, _settings),
    do: {:error, {:expected_public_protocol_secret_ref, value}}

  defp validate_value(%{type: :model_capabilities}, value, _key, _settings),
    do: ProviderCatalog.validate_capabilities(value)

  defp validate_value(%{type: :model_media}, value, _key, _settings),
    do: ProviderCatalog.validate_media(value)

  defp validate_value(%{type: :http_methods}, value, _key, _settings) when is_list(value) do
    allowed = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    if value != [] and Enum.all?(value, &(&1 in allowed)) do
      :ok
    else
      {:error, {:expected_http_methods, allowed}}
    end
  end

  defp validate_value(%{type: :http_methods}, value, _key, _settings),
    do: {:error, {:expected_http_methods, value}}

  defp validate_value(%{type: :external_service_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_external_service_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :external_service_profiles}, value, _key, _settings),
    do: {:error, {:expected_external_service_profiles, value}}

  defp validate_value(%{type: :command_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_command_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :command_profiles}, value, _key, _settings),
    do: {:error, {:expected_command_profiles, value}}

  defp validate_value(%{type: :interpreter_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_interpreter_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :interpreter_profiles}, value, _key, _settings),
    do: {:error, {:expected_interpreter_profiles, value}}

  defp validate_value(%{type: :package_manager_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_package_manager_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :package_manager_profiles}, value, _key, _settings),
    do: {:error, {:expected_package_manager_profiles, value}}

  defp validate_value(%{type: :resource_grants}, value, _key, _settings) when is_list(value) do
    Enum.reduce_while(value, :ok, fn grant, :ok ->
      case validate_resource_grant(grant) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :resource_grants}, value, _key, _settings),
    do: {:error, {:expected_resource_grants, value}}

  defp validate_value(%{type: :v13_origin_scopes}, value, _key, _settings)
       when is_list(value) do
    allowed = ~w[local_operator mapped_operator_dm e2ee_operator]

    if value == Enum.uniq(value) and Enum.all?(value, &(&1 in allowed)) do
      :ok
    else
      {:error, {:expected_v13_origin_scopes, value}}
    end
  end

  defp validate_value(%{type: :v13_origin_scopes}, value, _key, _settings),
    do: {:error, {:expected_v13_origin_scopes, value}}

  defp validate_value(%{type: :url_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :url_or_nil}, value, _key, _settings) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, :invalid_url}
    end
  end

  defp validate_value(%{type: :url_or_nil}, value, _key, _settings),
    do: {:error, {:expected_url, value}}

  defp validate_value(%{type: :secret_ref_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :secret_ref_or_nil}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^secret:\/\/providers\/[A-Za-z0-9_-]+\/api_key$/, value) do
      :ok
    else
      {:error, :invalid_secret_ref}
    end
  end

  defp validate_value(%{type: :secret_ref_or_nil}, value, _key, _settings),
    do: {:error, {:expected_secret_ref, value}}

  defp validate_value(%{type: :channel_secret_ref}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^secret:\/\/channels\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/, value) do
      :ok
    else
      {:error, :invalid_secret_ref}
    end
  end

  defp validate_value(%{type: :channel_secret_ref}, value, _key, _settings),
    do: {:error, {:expected_secret_ref, value}}

  defp validate_value(%{type: :mcp_secret_ref_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :mcp_secret_ref_or_nil}, value, _key, _settings)
       when is_binary(value) do
    if mcp_secret_ref?(value) do
      :ok
    else
      {:error, :invalid_secret_ref}
    end
  end

  defp validate_value(%{type: :mcp_secret_ref_or_nil}, value, _key, _settings),
    do: {:error, {:expected_secret_ref, value}}

  defp validate_value(%{type: :mcp_secret_ref_string_map}, value, _key, _settings)
       when is_map(value) do
    value
    |> Enum.reduce_while(:ok, fn {name, entry}, :ok ->
      cond do
        not valid_string_map_key?(name) ->
          {:halt, {:error, {:invalid_string_map_key, name}}}

        not is_binary(entry) ->
          {:halt, {:error, {:expected_string_map_value, name}}}

        secret_like_key?(name) and not mcp_secret_ref?(entry) ->
          {:halt, {:error, {:secret_value_requires_ref, name}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_value(%{type: :mcp_secret_ref_string_map}, value, _key, _settings),
    do: {:error, {:expected_string_map, value}}

  defp validate_value(%{type: :channel_identity_map}, value, _key, _settings)
       when is_list(value) do
    validate_channel_identity_map(value)
  end

  defp validate_value(%{type: :channel_identity_map}, value, _key, _settings),
    do: {:error, {:expected_channel_identity_map, value}}

  defp validate_value(%{type: :provider_ref}, value, _key, settings) when is_binary(value) do
    if is_map(settings["providers"]) && Map.has_key?(settings["providers"], value) do
      :ok
    else
      {:error, {:unknown_provider, value}}
    end
  end

  defp validate_value(%{type: :profile_ref}, value, _key, settings) when is_binary(value) do
    if is_map(settings["model_profiles"]) && Map.has_key?(settings["model_profiles"], value) do
      :ok
    else
      {:error, {:unknown_model_profile, value}}
    end
  end

  defp validate_value(%{type: :concrete_profile_ref_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :concrete_profile_ref_or_nil}, value, _key, settings)
       when is_binary(value) do
    cond do
      ModelRoles.reference?(value) ->
        {:error, {:role_reference_not_allowed, value}}

      is_map(settings["model_profiles"]) and Map.has_key?(settings["model_profiles"], value) ->
        :ok

      true ->
        {:error, {:unknown_model_profile, value}}
    end
  end

  defp validate_value(%{type: :concrete_profile_ref_or_nil}, value, _key, _settings),
    do: {:error, {:expected_concrete_profile_ref_or_nil, value}}

  defp validate_value(%{type: :task_profile_ref_list}, value, _key, settings)
       when is_list(value) do
    profiles = settings["model_profiles"]

    if is_map(profiles) and
         Enum.all?(value, fn reference ->
           is_binary(reference) and
             (ModelRoles.reference?(reference) or Map.has_key?(profiles, reference))
         end) do
      :ok
    else
      {:error, {:unknown_model_profile_or_role_in_list, value}}
    end
  end

  defp validate_value(%{type: :task_profile_ref_list}, value, _key, _settings),
    do: {:error, {:expected_task_profile_ref_list, value}}

  defp validate_value(%{type: :profile_ref_list}, value, _key, settings) when is_list(value) do
    profiles = settings["model_profiles"]

    if is_map(profiles) and Enum.all?(value, &(is_binary(&1) and Map.has_key?(profiles, &1))) do
      :ok
    else
      {:error, {:unknown_model_profile_in_list, value}}
    end
  end

  defp validate_value(%{type: :profile_ref_list}, value, _key, _settings),
    do: {:error, {:expected_profile_ref_list, value}}

  defp validate_value(%{type: :temperature}, value, _key, _settings) when is_number(value) do
    if value >= 0.0 and value <= 2.0, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :temperature}, value, _key, _settings),
    do: {:error, {:expected_number, value}}

  defp validate_value(%{type: :positive_integer}, value, _key, _settings)
       when is_integer(value) do
    if value >= 1 and value <= 100_000_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :bounded_integer, min: min, max: max}, value, _key, _settings)
       when is_integer(value) do
    if value >= min and value <= max, do: :ok, else: {:error, {:out_of_range, min, max}}
  end

  defp validate_value(%{type: :bounded_float, min: min, max: max}, value, _key, _settings)
       when is_number(value) do
    if value >= min and value <= max, do: :ok, else: {:error, {:out_of_range, min, max}}
  end

  defp validate_value(%{type: :bounded_float}, value, _key, _settings),
    do: {:error, {:expected_number, value}}

  defp validate_value(%{type: :non_negative_integer}, value, _key, _settings)
       when is_integer(value) do
    if value >= 0 and value <= 200_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :non_negative_integer_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :non_negative_integer_or_nil}, value, key, settings),
    do: validate_value(%{type: :non_negative_integer}, value, key, settings)

  defp validate_value(%{type: :timeout_ms}, value, _key, _settings) when is_integer(value) do
    if value >= 1_000 and value <= 600_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(schema, value, _key, _settings),
    do: {:error, {:invalid_value, schema.type, value}}

  defp loopback_http_base_url_error(uri) do
    [
      {uri.scheme not in ["http", "https"], :invalid_scheme},
      {not is_binary(uri.host) or uri.host == "", :missing_host},
      {is_binary(uri.userinfo) and uri.userinfo != "", :credentials_denied},
      {is_binary(uri.query) and uri.query != "", :query_denied},
      {is_binary(uri.fragment) and uri.fragment != "", :fragment_denied},
      {not loopback_setting_host?(uri.host), :non_loopback_host}
    ]
    |> Enum.find_value(fn
      {true, reason} -> reason
      {false, _reason} -> nil
    end)
  end

  defp validate_dynamic_codegen(settings) do
    with :ok <-
           validate_dynamic_codegen_list(
             settings,
             "dynamic_codegen.allowed_targets",
             ["action"]
           ),
         :ok <-
           validate_dynamic_codegen_list(
             settings,
             "dynamic_codegen.allowed_action_permissions",
             ["read_only", "memory_write", "external_network"]
           ),
         :ok <-
           validate_dynamic_codegen_list(
             settings,
             "dynamic_codegen.allowed_facades",
             ["append_memory", "external_network_request"],
             allow_empty?: true
           ) do
      validate_dynamic_codegen_list(
        settings,
        "dynamic_codegen.integration_approval_surfaces",
        ["cli", "liveview"]
      )
    end
  end

  defp validate_dynamic_codegen_list(settings, key, allowed_values, opts \\ []) do
    values = get_dotted(settings, key)
    allow_empty? = Keyword.get(opts, :allow_empty?, false)

    cond do
      not is_list(values) ->
        {:error, {:invalid_setting, key, {:expected_string_list, values}}}

      values == [] and not allow_empty? ->
        {:error, {:invalid_setting, key, :empty_list}}

      not Enum.all?(values, &(&1 in allowed_values)) ->
        {:error, {:invalid_setting, key, {:allowed_values, allowed_values}}}

      true ->
        :ok
    end
  end

  defp validate_templates(settings) do
    allowed_values = ~w[plugin app llm_tool flow objective]
    values = get_dotted(settings, "templates.allowed_patterns") || []

    cond do
      not is_list(values) ->
        {:error,
         {:invalid_setting, "templates.allowed_patterns", {:expected_string_list, values}}}

      not Enum.all?(values, &(&1 in allowed_values)) ->
        {:error,
         {:invalid_setting, "templates.allowed_patterns", {:allowed_values, allowed_values}}}

      true ->
        :ok
    end
  end

  defp validate_channels(settings) do
    with :ok <- validate_enabled_telegram(settings),
         :ok <- validate_enabled_email(settings) do
      :ok
    end
  end

  defp validate_enabled_telegram(settings) do
    if get_dotted(settings, "channels.telegram.enabled") do
      case get_dotted(settings, "channels.telegram.bot_token_ref") do
        value when is_binary(value) and value != "" ->
          :ok

        value ->
          {:error, {:invalid_setting, "channels.telegram.bot_token_ref", {:required, value}}}
      end
    else
      :ok
    end
  end

  defp validate_enabled_email(settings) do
    if get_dotted(settings, "channels.email.enabled") do
      with :ok <- require_non_empty_setting(settings, "channels.email.imap_host"),
           :ok <- require_non_empty_setting(settings, "channels.email.smtp_host"),
           :ok <- require_non_empty_setting(settings, "channels.email.imap_username"),
           :ok <- require_non_empty_setting(settings, "channels.email.smtp_username"),
           :ok <- require_non_empty_setting(settings, "channels.email.imap_password_ref"),
           :ok <- require_non_empty_setting(settings, "channels.email.smtp_password_ref"),
           :ok <- require_non_empty_setting(settings, "channels.email.from_address"),
           true <-
             get_dotted(settings, "channels.email.imap_ssl") ||
               {:error, {:invalid_setting, "channels.email.imap_ssl", :required}},
           true <-
             get_dotted(settings, "channels.email.smtp_tls") ||
               {:error, {:invalid_setting, "channels.email.smtp_tls", :required}} do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp require_non_empty_setting(settings, key) do
    case get_dotted(settings, key) do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, {:invalid_setting, key, {:required, value}}}
    end
  end

  defp validate_channel_identity_map(entries) do
    Enum.reduce_while(entries, MapSet.new(), fn entry, seen ->
      with :ok <- validate_channel_identity_entry(entry),
           external_user_id <- identity_field(entry, "external_user_id"),
           false <- MapSet.member?(seen, external_user_id) do
        {:cont, MapSet.put(seen, external_user_id)}
      else
        true ->
          {:halt,
           {:error, {:duplicate_external_user_id, identity_field(entry, "external_user_id")}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_channel_identity_entry(entry) when is_map(entry) do
    allowed = ~w[external_user_id user_id display_name enabled]
    keys = Map.keys(entry) |> Enum.map(&to_string/1)

    with nil <- Enum.find(keys, &(&1 not in allowed)),
         :ok <- validate_identity_string(entry, "external_user_id"),
         :ok <- validate_identity_string(entry, "user_id"),
         :ok <- validate_optional_identity_string(entry, "display_name"),
         :ok <- validate_optional_identity_boolean(entry, "enabled") do
      :ok
    else
      key when is_binary(key) -> {:error, {:channel_identity_unknown_key, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_channel_identity_entry(entry), do: {:error, {:invalid_channel_identity, entry}}

  defp validate_public_protocol_clients(clients, surface) when is_map(clients) do
    Enum.reduce_while(clients, :ok, fn {client_id, attrs}, :ok ->
      case validate_public_protocol_client(client_id, attrs, surface) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_public_protocol_clients(clients, _surface),
    do: {:error, {:expected_public_protocol_clients, clients}}

  defp validate_public_protocol_client(client_id, attrs, surface) when is_map(attrs) do
    with :ok <- TokenAuth.validate_client_id(client_id),
         :ok <- validate_public_protocol_client_keys(attrs),
         :ok <- validate_public_protocol_client_enabled(attrs),
         :ok <- validate_public_protocol_client_token_ref(client_id, attrs, surface) do
      validate_public_protocol_rate_limit(Map.get(attrs, "rate_limit", %{}))
    end
  end

  defp validate_public_protocol_client(client_id, _attrs, _surface),
    do: {:error, {:invalid_public_protocol_client, client_id, :expected_map}}

  defp validate_public_protocol_client_keys(attrs) do
    allowed = ~w[enabled token_ref rate_limit]

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.find(&(&1 not in allowed))
    |> case do
      nil -> :ok
      key -> {:error, {:public_protocol_client_unknown_key, key}}
    end
  end

  defp validate_public_protocol_client_enabled(attrs) do
    case Map.get(attrs, "enabled", Map.get(attrs, :enabled, false)) do
      value when is_boolean(value) -> :ok
      value -> {:error, {:public_protocol_client_invalid_enabled, value}}
    end
  end

  defp validate_public_protocol_client_token_ref(client_id, attrs, surface) do
    enabled? = Map.get(attrs, "enabled", Map.get(attrs, :enabled, false))

    case Map.get(attrs, "token_ref", Map.get(attrs, :token_ref)) do
      value when is_binary(value) ->
        validate_public_protocol_client_token_ref_value(value, surface, client_id)

      nil when enabled? == false ->
        :ok

      value ->
        {:error, {:public_protocol_client_invalid_token_ref, value}}
    end
  end

  defp validate_public_protocol_client_token_ref_value(value, surface, client_id) do
    case TokenAuth.parse_secret_ref(value) do
      {:ok, ^surface, ^client_id, "bearer_token"} ->
        :ok

      {:ok, other_surface, other_client_id, _name} ->
        {:error, {:token_ref_mismatch, other_surface, other_client_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_public_protocol_rate_limit(rate_limit) when is_map(rate_limit) do
    allowed = ~w[limit period_ms burst]

    with nil <- Enum.find(Map.keys(rate_limit), &(to_string(&1) not in allowed)),
         :ok <- validate_optional_rate_limit_field(rate_limit, "limit", 1, 10_000),
         :ok <- validate_optional_rate_limit_field(rate_limit, "period_ms", 100, 86_400_000) do
      validate_optional_rate_limit_field(rate_limit, "burst", 0, 10_000)
    else
      key when is_binary(key) -> {:error, {:public_protocol_rate_limit_unknown_key, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_public_protocol_rate_limit(rate_limit),
    do: {:error, {:public_protocol_rate_limit_expected_map, rate_limit}}

  defp validate_optional_rate_limit_field(rate_limit, key, min, max) do
    case Map.get(rate_limit, key, Map.get(rate_limit, String.to_atom(key))) do
      nil -> :ok
      value when is_integer(value) and value >= min and value <= max -> :ok
      value -> {:error, {:public_protocol_rate_limit_out_of_range, key, value, min, max}}
    end
  end

  defp validate_identity_string(entry, key) do
    value = identity_field(entry, key)

    if is_binary(value) and String.trim(value) != "" and String.length(value) <= 200 do
      :ok
    else
      {:error, {:channel_identity_invalid_string, key}}
    end
  end

  defp validate_optional_identity_string(entry, key) do
    case identity_field(entry, key) do
      nil -> :ok
      value when is_binary(value) and byte_size(value) <= 200 -> :ok
      _value -> {:error, {:channel_identity_invalid_string, key}}
    end
  end

  defp validate_optional_identity_boolean(entry, key) do
    case identity_field(entry, key) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _value -> {:error, {:channel_identity_invalid_boolean, key}}
    end
  end

  defp identity_field(entry, key), do: Map.get(entry, key, Map.get(entry, String.to_atom(key)))

  defp validate_resource_grant(grant) when is_map(grant) do
    with :ok <- validate_resource_grant_keys(grant),
         :ok <- validate_resource_grant_identity(grant),
         :ok <- validate_resource_grant_scope(grant),
         :ok <- validate_resource_grant_times(grant),
         :ok <- validate_optional_string_field(grant, "id"),
         :ok <- validate_optional_string_field(grant, "downstream_consumer"),
         :ok <- validate_optional_string_field(grant, "action_permission"),
         :ok <- validate_optional_string_field(grant, "origin_channel"),
         :ok <- validate_optional_string_field(grant, "resolver_channel"),
         :ok <- validate_optional_string_field(grant, "audit_path"),
         :ok <- validate_optional_string_field(grant, "reason") do
      validate_resource_grant_metadata(grant)
    end
  end

  defp validate_resource_grant(grant), do: {:error, {:invalid_resource_grant, grant}}

  defp validate_resource_grant_keys(grant) do
    keys = Map.keys(grant) |> Enum.map(&to_string/1)

    cond do
      missing = Enum.find(@resource_grant_required_keys, &(&1 not in keys)) ->
        {:error, {:resource_grant_missing_key, missing}}

      unknown = Enum.find(keys, &(&1 not in @resource_grant_allowed_keys)) ->
        {:error, {:resource_grant_unknown_key, unknown}}

      true ->
        :ok
    end
  end

  defp validate_resource_grant_identity(grant) do
    with {:ok, resource_uri} <-
           ResourceURI.normalize(resource_grant_field(grant, "resource_uri")),
         {:ok, derived} <- ResourceURI.derived_fields(resource_uri),
         {:ok, origin_kind} <-
           OperationClass.origin_kind(resource_grant_field(grant, "origin_kind")),
         {:ok, _operation_class} <-
           OperationClass.operation_class(resource_grant_field(grant, "operation_class")),
         {:ok, _access_mode} <-
           OperationClass.access_mode(resource_grant_field(grant, "access_mode")),
         true <-
           origin_kind == derived.origin_kind ||
             {:error, {:resource_uri_origin_kind_mismatch, origin_kind, derived.origin_kind}} do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_resource_grant_scope(grant) do
    scope = resource_grant_field(grant, "scope")

    with true <- is_map(scope) || {:error, {:resource_grant_invalid_scope, scope}},
         {:ok, _scope} <-
           Scope.new(
             resource_grant_scope_field(scope, "kind"),
             resource_grant_scope_field(scope, "value")
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_resource_grant_times(grant) do
    with :ok <-
           validate_required_datetime(resource_grant_field(grant, "created_at"), "created_at"),
         :ok <-
           validate_optional_datetime(resource_grant_field(grant, "expires_at"), "expires_at") do
      validate_optional_datetime(resource_grant_field(grant, "revoked_at"), "revoked_at")
    end
  end

  defp validate_required_datetime(value, key) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      {:error, reason} -> {:error, {:resource_grant_invalid_datetime, key, reason}}
    end
  end

  defp validate_required_datetime(value, key),
    do: {:error, {:resource_grant_invalid_datetime, key, value}}

  defp validate_optional_datetime(value, _key) when value in [nil, ""], do: :ok
  defp validate_optional_datetime(value, key), do: validate_required_datetime(value, key)

  defp validate_optional_string_field(grant, key) do
    case resource_grant_field(grant, key) do
      nil -> :ok
      value when is_binary(value) -> validate_non_empty_resource_grant_string(value, key)
      value -> {:error, {:resource_grant_expected_string, key, value}}
    end
  end

  defp validate_non_empty_resource_grant_string(value, key) do
    if String.trim(value) == "" do
      {:error, {:resource_grant_empty_string, key}}
    else
      :ok
    end
  end

  defp validate_resource_grant_metadata(grant) do
    case resource_grant_field(grant, "metadata", %{}) do
      metadata when is_map(metadata) -> :ok
      metadata -> {:error, {:resource_grant_expected_metadata_map, metadata}}
    end
  end

  defp resource_grant_field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Map.fetch!(@resource_grant_atom_keys, key), default))
  end

  defp resource_grant_scope_field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> nil
  end

  defp validate_timezone_name("UTC"), do: :ok

  defp validate_timezone_name(value) do
    if Regex.match?(~r/^[A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)?$/, value) do
      :ok
    else
      {:error, :invalid_timezone}
    end
  end

  defp reject_unknown_top_level(settings) do
    known = MapSet.new(Map.keys(defaults()))

    settings
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_setting, key}}
    end
  end

  defp wildcard_known_key?(key) do
    Regex.match?(~r/^providers\.[^.]+\.(type|enabled|endpoint_kind|base_url|api_key_ref)$/, key) ||
      Regex.match?(
        ~r/^model_profiles\.[^.]+\.(provider|model|aliases|capabilities|media|temperature|max_tokens|timeout_ms)$/,
        key
      ) ||
      Regex.match?(~r/^model_preferences\.(tasks|capabilities)\.[^.]+$/, key) ||
      Regex.match?(
        ~r/^mcp\.servers\.[^.]+\.(enabled|transport|command|args|env|base_url|headers|auth_ref|tool_allowlist|tool_denylist|confirmation)$/,
        key
      ) ||
      Regex.match?(
        ~r/^(mcp_server|openai_api)\.clients\.[^.]+\.(enabled|token_ref|rate_limit\.(limit|period_ms|burst))$/,
        key
      ) ||
      Regex.match?(
        ~r/^surface_policy\.surfaces\.[a-z0-9_]+\.[a-z0-9_]+\.(render_mode|redaction_profile|max_rows|raw_requires_affordance)$/,
        key
      )
  end

  defp validate_surface_policy(settings) do
    settings
    |> get_in(["surface_policy", "surfaces"])
    |> case do
      surfaces when is_map(surfaces) ->
        reduce_validation(surfaces, fn {surface, actions} ->
          validate_surface_policy_surface(surface, actions)
        end)

      other ->
        {:error, {:invalid_setting, "surface_policy.surfaces", {:expected_map, other}}}
    end
  end

  defp validate_surface_policy_surface(surface, actions)
       when is_binary(surface) and is_map(actions) do
    if Regex.match?(~r/^[a-z0-9_]+$/, surface) do
      reduce_validation(actions, fn {action, fields} ->
        validate_surface_policy_action(surface, action, fields)
      end)
    else
      {:error, {:invalid_setting, "surface_policy.surfaces", {:invalid_surface, surface}}}
    end
  end

  defp validate_surface_policy_surface(surface, _actions),
    do: {:error, {:invalid_setting, "surface_policy.surfaces", {:invalid_surface, surface}}}

  defp reduce_validation(enum, fun) do
    Enum.reduce_while(enum, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_surface_policy_action(surface, action, fields)
       when is_binary(action) and is_map(fields) do
    if Regex.match?(~r/^[a-z0-9_]+$/, action) do
      reduce_validation(fields, fn field_value ->
        validate_surface_policy_field(surface, action, field_value)
      end)
    else
      invalid_surface_policy_action(surface, action)
    end
  end

  defp validate_surface_policy_action(surface, action, _fields),
    do: invalid_surface_policy_action(surface, action)

  defp validate_surface_policy_field(surface, action, {field, value}) do
    key = "surface_policy.surfaces.#{surface}.#{action}.#{field}"

    if surface_policy_key?(key) do
      validate_surface_policy_field_value(key, field, value)
    else
      {:error, {:unknown_setting, key}}
    end
  end

  defp validate_surface_policy_field_value(key, field, value) do
    case validate_value(surface_policy_schema(field), value, key, %{}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_setting, key, reason}}
    end
  end

  defp invalid_surface_policy_action(surface, action) do
    {:error, {:invalid_setting, "surface_policy.surfaces.#{surface}", {:invalid_action, action}}}
  end

  defp surface_policy_key?(key) when is_binary(key) do
    Regex.match?(
      ~r/^surface_policy\.surfaces\.[a-z0-9_]+\.[a-z0-9_]+\.(render_mode|redaction_profile|max_rows|raw_requires_affordance)$/,
      key
    )
  end

  defp surface_policy_field(key) do
    key
    |> split_key()
    |> List.last()
  end

  defp surface_policy_schema("render_mode") do
    %{type: :enum, allowed_values: ["assistant_summary", "operator_report"]}
  end

  defp surface_policy_schema("redaction_profile") do
    %{type: :enum, allowed_values: ["standard", "strict"]}
  end

  defp surface_policy_schema("max_rows") do
    %{type: :bounded_integer, min: 0, max: 1000}
  end

  defp surface_policy_schema("raw_requires_affordance"), do: %{type: :boolean}

  defp public_protocol_client_key?(key) do
    Regex.match?(
      ~r/^(mcp_server|openai_api)\.clients\.[^.]+\.(enabled|token_ref|rate_limit\.(limit|period_ms|burst))$/,
      key
    )
  end

  defp public_protocol_client_field(key) do
    key
    |> split_key()
    |> Enum.drop(3)
    |> Enum.join(".")
  end

  defp default_key?(key) do
    defaults()
    |> flatten_default_keys()
    |> MapSet.member?(key)
  end

  defp flatten_default_keys(map, prefix \\ [])

  defp flatten_default_keys(map, prefix) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} -> flatten_default_keys(value, prefix ++ [key]) end)
    |> MapSet.new()
  end

  defp flatten_default_keys(_value, prefix), do: [Enum.join(prefix, ".")]

  defp key_matches?(pattern, key) do
    pattern_parts = split_key(pattern)
    key_parts = split_key(key)

    length(pattern_parts) == length(key_parts) &&
      Enum.zip(pattern_parts, key_parts)
      |> Enum.all?(fn
        {"*", part} -> part != ""
        {part, part} -> true
        _other -> false
      end)
  end

  defp split_key(key), do: String.split(key, ".", trim: true)

  @doc false
  def app_schema do
    :app
    |> safe_registered_settings()
    |> Enum.flat_map(&normalize_app_schema_entry/1)
    |> Map.new()
  end

  @doc false
  def app_defaults do
    app_schema()
    |> Enum.reduce(%{}, fn {key, schema}, defaults ->
      put_dotted(defaults, key, Map.fetch!(schema, :default))
    end)
  end

  @doc false
  def app_safe_write_keys do
    app_schema()
    |> Enum.filter(fn {_key, schema} -> Map.get(schema, :writable?, true) end)
    |> Enum.map(fn {key, _schema} -> key end)
  end

  @doc false
  def plugin_schema do
    :plugin
    |> safe_registered_settings()
    |> Enum.flat_map(&normalize_plugin_schema_entry(&1, []))
    |> Map.new()
  end

  @doc false
  def plugin_defaults do
    plugin_schema()
    |> Enum.reduce(%{}, fn {key, schema}, defaults ->
      put_dotted(defaults, key, Map.fetch!(schema, :default))
    end)
  end

  @doc false
  def plugin_safe_write_keys do
    plugin_schema()
    |> Enum.filter(fn {_key, schema} -> Map.get(schema, :writable?, true) end)
    |> Enum.map(fn {key, _schema} -> key end)
  end

  defp safe_registered_settings(:app) do
    AppRegistry.registered_settings_schema()
  rescue
    exception ->
      Logger.warning("App settings schema unavailable: #{Exception.message(exception)}")
      []
  catch
    :exit, reason ->
      Logger.warning("App settings schema unavailable: #{inspect(reason)}")
      []
  end

  defp safe_registered_settings(:plugin) do
    PluginRegistry.registered_settings_schema()
  rescue
    exception ->
      Logger.warning("Plugin settings schema unavailable: #{Exception.message(exception)}")
      []
  catch
    :exit, reason ->
      Logger.warning("Plugin settings schema unavailable: #{inspect(reason)}")
      []
  end

  @doc false
  def normalize_app_schema_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_app_schema_entry/1)
    |> Map.new()
  end

  def normalize_app_schema_entries(_entries), do: %{}

  @doc false
  def normalize_app_schema_entries_checked(entries) when is_list(entries) do
    normalize_schema_entries_checked(
      entries,
      &checked_normalization(normalize_app_schema_entry(&1)),
      :app
    )
  end

  def normalize_app_schema_entries_checked(_entries),
    do: {:error, {:invalid_app_settings_schema, :not_a_list}}

  defp normalize_app_schema_entry(entry) when is_map(entry) do
    key = schema_field(entry, :key)

    if valid_app_setting_key?(key) do
      normalize_schema_entry(entry)
    else
      []
    end
  end

  defp normalize_app_schema_entry(_entry), do: []

  @doc false
  def normalize_plugin_schema_entries(entries, opts \\ [])

  def normalize_plugin_schema_entries(entries, opts) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_plugin_schema_entry(&1, opts))
    |> Map.new()
  end

  def normalize_plugin_schema_entries(_entries, _opts), do: %{}

  @doc false
  def normalize_plugin_schema_entries_checked(entries, opts \\ [])

  def normalize_plugin_schema_entries_checked(entries, opts) when is_list(entries) do
    normalize_schema_entries_checked(
      entries,
      &normalize_plugin_schema_entry_checked(&1, opts),
      :plugin
    )
  end

  def normalize_plugin_schema_entries_checked(_entries, _opts),
    do: {:error, {:invalid_plugin_settings_schema, :not_a_list}}

  defp normalize_plugin_schema_entry(entry, opts) when is_map(entry) do
    key = schema_field(entry, :key)

    cond do
      valid_plugin_setting_key?(key) ->
        normalize_schema_entry(entry)

      channel_setting_key_allowed?(key, opts) ->
        normalize_schema_entry(entry)

      Map.has_key?(core_schema(), key) and not channel_setting_key?(key) ->
        normalize_schema_entry(entry)

      true ->
        []
    end
  end

  defp normalize_plugin_schema_entry(_entry, _opts), do: []

  defp normalize_schema_entry(entry) when is_map(entry) do
    key = schema_field(entry, :key)
    type = schema_field(entry, :type)

    cond do
      not is_binary(key) ->
        []

      not is_atom(type) ->
        []

      not has_schema_field?(entry, :default) ->
        []

      true ->
        [{key, plugin_schema_attrs(entry, type)}]
    end
  end

  defp normalize_schema_entries_checked(entries, normalizer, source) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {entry, index}, {:ok, schema, seen} ->
      reduce_schema_entry(normalizer.(entry), index, schema, seen, source)
    end)
    |> case do
      {:ok, schema, _seen} -> {:ok, schema}
      {:error, _reason} = error -> error
    end
  end

  defp reduce_schema_entry({:entry, key, attrs}, _index, schema, seen, source) do
    if MapSet.member?(seen, key) do
      {:halt, {:error, {duplicate_schema_reason(source), key}}}
    else
      {:cont, {:ok, Map.put(schema, key, attrs), MapSet.put(seen, key)}}
    end
  end

  defp reduce_schema_entry({:binding, key}, _index, schema, seen, source) do
    if MapSet.member?(seen, key) do
      {:halt, {:error, {duplicate_schema_reason(source), key}}}
    else
      {:cont, {:ok, schema, MapSet.put(seen, key)}}
    end
  end

  defp reduce_schema_entry(_invalid, index, _schema, _seen, source) do
    {:halt, {:error, {invalid_schema_reason(source), index}}}
  end

  defp invalid_schema_reason(:app), do: :invalid_app_settings_schema_entry
  defp invalid_schema_reason(:plugin), do: :invalid_plugin_settings_schema_entry
  defp duplicate_schema_reason(:app), do: :duplicate_app_settings_schema_key
  defp duplicate_schema_reason(:plugin), do: :duplicate_plugin_settings_schema_key

  defp checked_normalization([{key, attrs}]), do: {:entry, key, attrs}
  defp checked_normalization(_invalid), do: :invalid

  defp normalize_plugin_schema_entry_checked(entry, opts) do
    case normalize_plugin_schema_entry(entry, opts) do
      [{key, attrs}] ->
        {:entry, key, attrs}

      [] ->
        if valid_plugin_schema_binding?(entry, opts), do: {:binding, schema_field(entry, :key)}
    end
  end

  defp valid_plugin_schema_binding?(entry, opts) when is_map(entry) do
    key = schema_field(entry, :key)
    type = schema_field(entry, :type)
    core_entry = if is_binary(key), do: Map.get(core_schema(), key)

    is_binary(key) and is_atom(type) and not has_schema_field?(entry, :default) and
      is_map(core_entry) and Map.get(core_entry, :type) == type and
      (channel_setting_key_allowed?(key, opts) or
         (not channel_setting_key?(key) and Map.has_key?(core_schema(), key)))
  end

  defp valid_plugin_schema_binding?(_entry, _opts), do: false

  defp plugin_schema_attrs(entry, type) do
    %{
      type: type,
      default: schema_field(entry, :default),
      writable?: schema_field(entry, :writable?, true),
      sensitive?: schema_field(entry, :sensitive?, sensitive_key?(schema_field(entry, :key)))
    }
    |> maybe_put_schema_attr(:allowed_values, schema_field(entry, :allowed_values))
    |> maybe_put_schema_attr(:min, schema_field(entry, :min))
    |> maybe_put_schema_attr(:max, schema_field(entry, :max))
  end

  defp maybe_put_schema_attr(schema, _key, nil), do: schema
  defp maybe_put_schema_attr(schema, key, value), do: Map.put(schema, key, value)

  defp schema_field(entry, key, default \\ nil) do
    Map.get(entry, key, Map.get(entry, Atom.to_string(key), default))
  end

  defp has_schema_field?(entry, key) do
    Map.has_key?(entry, key) or Map.has_key?(entry, Atom.to_string(key))
  end

  defp valid_plugin_setting_key?(key) when is_binary(key) do
    byte_size(key) <= 160 and
      Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, key) and
      (String.starts_with?(key, "plugins.") or
         key
         |> split_key()
         |> List.first()
         |> reserved_plugin_settings_namespace?()
         |> Kernel.not())
  end

  defp valid_plugin_setting_key?(_key), do: false

  defp channel_setting_key_allowed?(key, opts) when is_binary(key) do
    channel_setting_key?(key) and trusted_source_tree_plugin?(Keyword.get(opts, :plugin)) and
      Enum.any?(channel_settings_prefixes(Keyword.get(opts, :plugin)), fn prefix ->
        key == prefix or String.starts_with?(key, prefix <> ".")
      end)
  end

  defp channel_setting_key_allowed?(_key, _opts), do: false

  defp channel_setting_key?(key) when is_binary(key), do: String.starts_with?(key, "channels.")
  defp channel_setting_key?(_key), do: false

  defp trusted_source_tree_plugin?(plugin) when is_map(plugin) do
    Map.get(plugin, :source) in [:shipped, :project] and
      Map.get(plugin, :trust_status) == :trusted
  end

  defp trusted_source_tree_plugin?(_plugin), do: false

  defp channel_settings_prefixes(plugin) when is_map(plugin) do
    plugin
    |> Map.get(:channels, [])
    |> Enum.flat_map(fn
      %{settings_prefix: prefix} when is_binary(prefix) -> [prefix]
      %{"settings_prefix" => prefix} when is_binary(prefix) -> [prefix]
      _descriptor -> []
    end)
    |> Enum.uniq()
  end

  defp channel_settings_prefixes(_plugin), do: []

  defp reserved_plugin_settings_namespace?(namespace) do
    namespace in [
      "agents",
      "apps",
      "channels",
      "confirmations",
      "execution",
      "external_services",
      "intent",
      "jobs",
      "memory",
      "model_profiles",
      "operator",
      "package_installs",
      "permissions",
      "providers",
      "resource_grants",
      "runtime",
      "sessions",
      "skills",
      "workspace"
    ]
  end

  defp valid_app_setting_key?(key) when is_binary(key) do
    byte_size(key) <= 160 and Regex.match?(~r/^apps\.[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, key)
  end

  defp valid_app_setting_key?(_key), do: false

  defp put_in_segments(_settings, [], value), do: value

  defp put_in_segments(settings, [segment], value) when is_map(settings) do
    Map.put(settings, segment, value)
  end

  defp put_in_segments(settings, [segment | rest], value) when is_map(settings) do
    child =
      settings
      |> Map.get(segment, %{})
      |> case do
        map when is_map(map) -> map
        _other -> %{}
      end

    Map.put(settings, segment, put_in_segments(child, rest, value))
  end

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, name)

  defp valid_string_list_item?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_string_map_key?(value), do: is_binary(value) and String.trim(value) != ""

  defp secret_like_key?(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.any?(&(&1 in ["authorization", "secret", "token", "password", "api", "key"]))
  end

  defp safe_mcp_launcher?(launcher) when is_binary(launcher) do
    launcher = String.trim(launcher)

    launcher != "" and
      (bare_mcp_launcher?(launcher) or absolute_mcp_launcher?(launcher)) and
      not String.contains?(launcher, [" ", "\t", "\n", "\r"])
  end

  defp safe_mcp_launcher?(_launcher), do: false

  defp bare_mcp_launcher?(launcher) do
    not String.contains?(launcher, ["/", "\\", "\0"])
  end

  defp absolute_mcp_launcher?(launcher) do
    parts = Path.split(launcher)

    String.starts_with?(launcher, "/") and
      length(parts) > 1 and
      not String.contains?(launcher, ["\\", "\0"]) and
      Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  defp mcp_secret_ref?(value) when is_binary(value) do
    Regex.match?(~r/^secret:\/\/mcp\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/, value)
  end

  defp valid_email?(value) when is_binary(value) do
    String.length(value) <= 254 and
      Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value)
  end

  defp validate_command_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_command_profile, name, :expected_map}}

      true ->
        validate_command_profile_attrs(name, profile)
    end
  end

  defp validate_command_profile_attrs(name, profile) do
    allowed_keys =
      [
        "command",
        "args_prefix",
        "command_class",
        "description",
        "allowed_roots",
        "env_allowlist",
        "timeout_ms",
        "max_output_bytes",
        "require_confirmation"
      ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_command_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_command_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_command_profile_values(name, profile) do
    with :ok <- validate_required_profile_command(name, profile),
         :ok <- validate_optional_string_list(profile, "args_prefix"),
         :ok <- validate_optional_string_list(profile, "allowed_roots"),
         :ok <- validate_optional_string_list(profile, "env_allowlist"),
         :ok <- validate_optional_timeout(profile, "timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_output_bytes"),
         :ok <- validate_optional_boolean(profile, "require_confirmation") do
      validate_optional_command_class(name, profile)
    end
  end

  defp validate_required_profile_command(name, profile) do
    case Map.get(profile, "command") do
      command when is_binary(command) ->
        if String.trim(command) == "" do
          {:error, {:invalid_command_profile, name, :empty_command}}
        else
          :ok
        end

      other ->
        {:error, {:invalid_command_profile, name, {:expected_command, other}}}
    end
  end

  defp validate_optional_command_class(name, profile) do
    case Map.get(profile, "command_class", "developer") do
      class when class in ["read_only", "developer", "mutating"] ->
        :ok

      other ->
        {:error, {:invalid_command_profile, name, {:invalid_command_class, other}}}
    end
  end

  defp validate_external_service_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_external_service_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_external_service_profile, name, :expected_map}}

      true ->
        validate_external_service_profile_attrs(name, profile)
    end
  end

  defp validate_external_service_profile_attrs(name, profile) do
    allowed_keys = [
      "enabled",
      "base_url",
      "allowed_hosts",
      "blocked_hosts",
      "allowed_paths",
      "allowed_methods",
      "default_timeout_ms",
      "max_timeout_ms",
      "max_response_bytes",
      "allow_redirects",
      "max_redirects",
      "retry_policy",
      "redact_request_headers",
      "redact_response_headers",
      "description"
    ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_external_service_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_external_service_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_external_service_profile_values(_name, profile) do
    with :ok <- validate_optional_boolean(profile, "enabled"),
         :ok <- validate_optional_url_or_nil(profile, "base_url"),
         :ok <- validate_optional_string_list(profile, "allowed_hosts"),
         :ok <- validate_optional_string_list(profile, "blocked_hosts"),
         :ok <- validate_optional_string_list(profile, "allowed_paths"),
         :ok <- validate_optional_http_methods(profile, "allowed_methods"),
         :ok <- validate_optional_timeout(profile, "default_timeout_ms"),
         :ok <- validate_optional_timeout(profile, "max_timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_response_bytes"),
         :ok <- validate_optional_boolean(profile, "allow_redirects"),
         :ok <- validate_optional_non_negative_integer(profile, "max_redirects"),
         :ok <- validate_optional_retry_policy(profile, "retry_policy"),
         :ok <- validate_optional_string_list(profile, "redact_request_headers") do
      validate_optional_string_list(profile, "redact_response_headers")
    end
  end

  defp validate_package_manager_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_package_manager_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_package_manager_profile, name, :expected_map}}

      true ->
        validate_package_manager_profile_attrs(name, profile)
    end
  end

  defp validate_package_manager_profile_attrs(name, profile) do
    allowed_keys = [
      "executable",
      "args_prefix",
      "plan_args",
      "install_args",
      "description",
      "allowed_roots",
      "timeout_ms",
      "max_output_bytes",
      "require_confirmation",
      "lifecycle_scripts_allowed",
      "git_dependencies_allowed",
      "global_installs_allowed"
    ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_package_manager_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_package_manager_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_package_manager_profile_values(name, profile) do
    with :ok <- validate_required_package_manager_executable(name, profile),
         :ok <- validate_optional_string_list(profile, "args_prefix"),
         :ok <- validate_optional_string_list(profile, "plan_args"),
         :ok <- validate_optional_string_list(profile, "install_args"),
         :ok <- validate_optional_string_list(profile, "allowed_roots"),
         :ok <- validate_optional_timeout(profile, "timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_output_bytes"),
         :ok <- validate_optional_boolean(profile, "require_confirmation"),
         :ok <- validate_optional_boolean(profile, "lifecycle_scripts_allowed"),
         :ok <- validate_optional_boolean(profile, "git_dependencies_allowed") do
      validate_optional_boolean(profile, "global_installs_allowed")
    end
  end

  defp validate_optional_string_list(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :string_list}, value, key, %{})
    end
  end

  defp validate_optional_http_methods(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :http_methods}, value, key, %{})
    end
  end

  defp validate_optional_url_or_nil(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :url_or_nil}, value, key, %{})
    end
  end

  defp validate_optional_timeout(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :timeout_ms}, value, key, %{})
    end
  end

  defp validate_optional_positive_integer(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :positive_integer}, value, key, %{})
    end
  end

  defp validate_optional_non_negative_integer(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :non_negative_integer}, value, key, %{})
    end
  end

  defp validate_optional_boolean(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :boolean}, value, key, %{})
    end
  end

  defp validate_optional_retry_policy(profile, key) do
    case Map.fetch(profile, key) do
      :error ->
        :ok

      {:ok, value} ->
        validate_value(
          %{type: :enum, allowed_values: ["none", "safe_idempotent"]},
          value,
          key,
          %{}
        )
    end
  end

  defp validate_interpreter_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_interpreter_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_interpreter_profile, name, :expected_map}}

      true ->
        validate_interpreter_profile_attrs(name, profile)
    end
  end

  defp validate_interpreter_profile_attrs(name, profile) do
    allowed_keys = [
      "executable",
      "allowed_extensions",
      "args_prefix",
      "command_class",
      "description",
      "timeout_ms",
      "max_output_bytes",
      "require_confirmation"
    ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_interpreter_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_interpreter_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_interpreter_profile_values(name, profile) do
    with :ok <- validate_required_profile_executable(name, profile),
         :ok <- validate_required_allowed_extensions(name, profile),
         :ok <- validate_optional_string_list(profile, "args_prefix"),
         :ok <- validate_optional_timeout(profile, "timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_output_bytes"),
         :ok <- validate_optional_boolean(profile, "require_confirmation") do
      validate_optional_interpreter_command_class(name, profile)
    end
  end

  defp validate_required_profile_executable(name, profile) do
    case Map.get(profile, "executable") do
      executable when is_binary(executable) ->
        if String.trim(executable) == "" do
          {:error, {:invalid_interpreter_profile, name, :empty_executable}}
        else
          :ok
        end

      other ->
        {:error, {:invalid_interpreter_profile, name, {:expected_executable, other}}}
    end
  end

  defp validate_required_package_manager_executable(name, profile) do
    case Map.get(profile, "executable") do
      executable when is_binary(executable) ->
        if String.trim(executable) == "" do
          {:error, {:invalid_package_manager_profile, name, :empty_executable}}
        else
          :ok
        end

      other ->
        {:error, {:invalid_package_manager_profile, name, {:expected_executable, other}}}
    end
  end

  defp validate_required_allowed_extensions(name, profile) do
    case Map.get(profile, "allowed_extensions") do
      extensions when is_list(extensions) ->
        if Enum.all?(extensions, &valid_extension?/1) do
          :ok
        else
          {:error, {:invalid_interpreter_profile, name, :invalid_allowed_extensions}}
        end

      other ->
        {:error, {:invalid_interpreter_profile, name, {:expected_allowed_extensions, other}}}
    end
  end

  defp validate_optional_interpreter_command_class(name, profile) do
    case Map.get(profile, "command_class", "developer") do
      class when class in ["read_only", "developer", "mutating"] ->
        :ok

      other ->
        {:error, {:invalid_interpreter_profile, name, {:invalid_command_class, other}}}
    end
  end

  defp valid_extension?("." <> rest), do: valid_extension_name?(rest)
  defp valid_extension?(value), do: valid_extension_name?(value)

  defp valid_extension_name?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Za-z0-9_+-]+$/, value)
  end

  defp valid_extension_name?(_value), do: false

  defp loopback_setting_host?(host)
       when host in ["localhost", "localhost.localdomain", "127.0.0.1", "::1"],
       do: true

  defp loopback_setting_host?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _result -> false
    end
  end

  defp loopback_setting_host?(_host), do: false
end
