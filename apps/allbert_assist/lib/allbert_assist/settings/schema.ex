defmodule AllbertAssist.Settings.Schema do
  @moduledoc false

  @safe_write_keys [
    "operator.display_name",
    "operator.timezone",
    "operator.communication_style",
    "operator.handoff_detail",
    "runtime.trace_default",
    "runtime.diagnostics_verbosity",
    "providers.*.enabled",
    "providers.*.base_url",
    "providers.*.api_key_ref",
    "model_profiles.*.provider",
    "model_profiles.*.model",
    "model_profiles.*.temperature",
    "model_profiles.*.max_tokens",
    "model_profiles.*.timeout_ms",
    "skills.scan_paths",
    "skills.trusted_project_roots",
    "skills.enabled",
    "skills.disabled",
    "skills.imported_cache_policy",
    "permissions.memory_write",
    "permissions.command_plan",
    "permissions.command_execute",
    "permissions.external_network",
    "permissions.settings_write",
    "permissions.skill_write",
    "channels.cli.response_style",
    "channels.live_view.response_style"
  ]

  @schema %{
    "operator.display_name" => %{
      type: :string,
      default: "local",
      writable?: true,
      sensitive?: false
    },
    "operator.timezone" => %{
      type: :timezone,
      default: "America/Los_Angeles",
      writable?: true,
      sensitive?: false
    },
    "operator.communication_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "operator.handoff_detail" => %{
      type: :enum,
      default: "concrete_next_steps",
      writable?: true,
      sensitive?: false,
      allowed_values: ["brief", "concrete_next_steps", "full_context"]
    },
    "runtime.trace_default" => %{
      type: :enum,
      default: "disabled",
      writable?: true,
      sensitive?: false,
      allowed_values: ["disabled", "enabled", "denied_only"]
    },
    "runtime.diagnostics_verbosity" => %{
      type: :enum,
      default: "normal",
      writable?: true,
      sensitive?: false,
      allowed_values: ["quiet", "normal", "verbose"]
    },
    "runtime.model_alias" => %{
      type: :profile_ref,
      default: "local",
      writable?: false,
      sensitive?: false
    },
    "runtime.cost_visibility" => %{
      type: :enum,
      default: "summary",
      writable?: false,
      sensitive?: false,
      allowed_values: ["hidden", "summary", "detailed"]
    },
    "channels.cli.response_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "channels.live_view.response_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "skills.scan_paths" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.trusted_project_roots" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.enabled" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.disabled" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.imported_cache_policy" => %{
      type: :enum,
      default: "disabled",
      writable?: true,
      sensitive?: false,
      allowed_values: ["disabled", "enabled_manual_trust"]
    },
    "permissions.memory_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.command_plan" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.command_execute" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.external_network" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.settings_write" => %{
      type: :enum,
      default: "allowed_safe_keys",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed_safe_keys", "needs_confirmation", "denied"]
    },
    "permissions.skill_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "jobs.timezone" => %{
      type: :timezone,
      default: "America/Los_Angeles",
      writable?: false,
      sensitive?: false
    },
    "jobs.default_state" => %{
      type: :enum,
      default: "paused",
      writable?: false,
      sensitive?: false,
      allowed_values: ["paused", "active"]
    },
    "jobs.schedule_policy" => %{
      type: :enum,
      default: "operator_approved",
      writable?: false,
      sensitive?: false,
      allowed_values: ["operator_approved", "paused"]
    },
    "memory.review_cadence" => %{
      type: :enum,
      default: "manual",
      writable?: false,
      sensitive?: false,
      allowed_values: ["manual", "daily", "weekly"]
    },
    "memory.auto_promote_sensitive_entries" => %{
      type: :boolean,
      default: false,
      writable?: false,
      sensitive?: false
    },
    "memory.retention_policy" => %{
      type: :enum,
      default: "preserve_markdown",
      writable?: false,
      sensitive?: false,
      allowed_values: ["preserve_markdown"]
    }
  }

  @provider_schema %{
    "type" => %{
      type: :enum,
      allowed_values: ["openai", "openai_compatible", "anthropic", "local"]
    },
    "enabled" => %{type: :boolean},
    "base_url" => %{type: :url_or_nil},
    "api_key_ref" => %{type: :secret_ref_or_nil}
  }

  @model_profile_schema %{
    "provider" => %{type: :provider_ref},
    "model" => %{type: :string},
    "temperature" => %{type: :temperature},
    "max_tokens" => %{type: :positive_integer},
    "timeout_ms" => %{type: :timeout_ms}
  }

  @defaults %{
    "operator" => %{
      "display_name" => "local",
      "timezone" => "America/Los_Angeles",
      "communication_style" => "concise",
      "handoff_detail" => "concrete_next_steps"
    },
    "runtime" => %{
      "trace_default" => "disabled",
      "diagnostics_verbosity" => "normal",
      "model_alias" => "local",
      "cost_visibility" => "summary"
    },
    "providers" => %{
      "local_ollama" => %{
        "type" => "openai_compatible",
        "base_url" => "http://localhost:11434/v1",
        "api_key_ref" => nil,
        "enabled" => true
      },
      "openai" => %{
        "type" => "openai",
        "api_key_ref" => "secret://providers/openai/api_key",
        "enabled" => false
      }
    },
    "model_profiles" => %{
      "local" => %{
        "provider" => "local_ollama",
        "model" => "gemma4:26b",
        "temperature" => 0.2,
        "max_tokens" => 1024,
        "timeout_ms" => 30_000
      },
      "fast" => %{
        "provider" => "openai",
        "model" => "gpt-4o-mini",
        "temperature" => 0.2,
        "max_tokens" => 1024,
        "timeout_ms" => 30_000
      }
    },
    "agents" => %{
      "primary_intent" => %{
        "type" => "code",
        "module" => "AllbertAssist.Agents.IntentAgent",
        "model_profile" => "local",
        "enabled" => true
      }
    },
    "skills" => %{
      "scan_paths" => [],
      "trusted_project_roots" => [],
      "enabled" => [],
      "disabled" => [],
      "imported_cache_policy" => "disabled"
    },
    "permissions" => %{
      "memory_write" => "allowed",
      "command_plan" => "allowed",
      "command_execute" => "denied",
      "external_network" => "needs_confirmation",
      "settings_write" => "allowed_safe_keys",
      "skill_write" => "allowed"
    },
    "channels" => %{
      "cli" => %{"enabled" => true, "response_style" => "concise"},
      "live_view" => %{"enabled" => true, "response_style" => "concise"}
    },
    "jobs" => %{
      "timezone" => "America/Los_Angeles",
      "default_state" => "paused",
      "schedule_policy" => "operator_approved"
    },
    "memory" => %{
      "review_cadence" => "manual",
      "auto_promote_sensitive_entries" => false,
      "retention_policy" => "preserve_markdown"
    }
  }

  def defaults, do: @defaults
  def schema, do: @schema
  def safe_write_keys, do: @safe_write_keys

  def safe_write_key?(key) when is_binary(key) do
    Enum.any?(@safe_write_keys, &key_matches?(&1, key))
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
         :ok <- validate_runtime_refs(settings) do
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
    Map.has_key?(@schema, key) ||
      wildcard_known_key?(key) ||
      default_key?(key)
  end

  def sensitive_key?(key) do
    key
    |> String.split(~r/[._-]/, trim: true)
    |> Enum.any?(&(&1 in ["secret", "token", "password", "api", "key", "private", "credential"]))
  end

  defp validate_known_key_value(key, value, settings) do
    schema_for_key(key)
    |> validate_value(value, key, settings)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_setting, key, reason}}
    end
  end

  defp schema_for_key(key) do
    cond do
      schema = Map.get(@schema, key) ->
        schema

      Regex.match?(~r/^providers\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@provider_schema, &1))

      Regex.match?(~r/^model_profiles\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@model_profile_schema, &1))
    end
  end

  defp validate_static_keys(settings) do
    @schema
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
        validate_dynamic_map(profiles, @model_profile_schema, "model_profiles", settings)

      other ->
        {:error, {:invalid_setting, "model_profiles", {:expected_map, other}}}
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

  defp validate_value(%{type: :string_list}, value, _key, _settings) when is_list(value) do
    if Enum.all?(value, &valid_string_list_item?/1) do
      :ok
    else
      {:error, {:expected_string_list, value}}
    end
  end

  defp validate_value(%{type: :string_list}, value, _key, _settings),
    do: {:error, {:expected_string_list, value}}

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

  defp validate_value(%{type: :temperature}, value, _key, _settings) when is_number(value) do
    if value >= 0.0 and value <= 2.0, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :temperature}, value, _key, _settings),
    do: {:error, {:expected_number, value}}

  defp validate_value(%{type: :positive_integer}, value, _key, _settings)
       when is_integer(value) do
    if value >= 1 and value <= 200_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :timeout_ms}, value, _key, _settings) when is_integer(value) do
    if value >= 1_000 and value <= 600_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(schema, value, _key, _settings),
    do: {:error, {:invalid_value, schema.type, value}}

  defp validate_timezone_name("UTC"), do: :ok

  defp validate_timezone_name(value) do
    if Regex.match?(~r/^[A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)?$/, value) do
      :ok
    else
      {:error, :invalid_timezone}
    end
  end

  defp reject_unknown_top_level(settings) do
    known = MapSet.new(Map.keys(@defaults))

    settings
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_setting, key}}
    end
  end

  defp wildcard_known_key?(key) do
    Regex.match?(~r/^providers\.[^.]+\.(type|enabled|base_url|api_key_ref)$/, key) ||
      Regex.match?(
        ~r/^model_profiles\.[^.]+\.(provider|model|temperature|max_tokens|timeout_ms)$/,
        key
      )
  end

  defp default_key?(key) do
    @defaults
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
end
