defmodule AllbertAssist.Settings do
  @moduledoc """
  Settings Central for Allbert-owned operator configuration.
  """

  alias AllbertAssist.Memory.ReviewCadence
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @legacy_key_aliases %{
    "workspace.theme" => "workspace.theme.mode"
  }

  defdelegate root(), to: Store
  defdelegate ensure_root!(), to: Store
  defdelegate read_user_settings(), to: Store
  defdelegate write_user_settings(settings, opts \\ []), to: Store

  def defaults, do: Schema.defaults()
  def schema, do: Schema.schema()
  def safe_write_keys, do: Schema.safe_write_keys()

  def known_key?(key) when is_binary(key), do: key |> canonical_key() |> Schema.known_key?()

  def safe_write_key?(key) when is_binary(key),
    do: key |> canonical_key() |> Schema.safe_write_key?()

  def list(namespace_or_opts \\ []) do
    namespace = namespace(namespace_or_opts)

    with {:ok, settings, user_settings} <- Store.resolved_settings() do
      settings
      |> flatten()
      |> Enum.filter(fn {key, _value} ->
        is_nil(namespace) or String.starts_with?(key, namespace)
      end)
      |> Enum.map(fn {key, value} -> resolved_setting(key, value, settings, user_settings) end)
      |> Enum.sort_by(& &1.key)
      |> then(&{:ok, &1})
    end
  end

  def get(key, context \\ %{}) when is_binary(key) do
    with {:ok, resolved} <- resolve(key, context) do
      {:ok, resolved.value}
    end
  end

  def put(key, value, context \\ %{}) when is_binary(key) do
    key = canonical_key(key)

    with {:ok, settings, user_settings, diagnostics} <-
           Store.put_user_setting(key, value, context) do
      diagnostics = diagnostics ++ post_write_diagnostics(key, value, context)
      resolved = resolved_setting(key, Schema.get_dotted(settings, key), settings, user_settings)

      {:ok,
       resolved
       |> Map.put(:context, sanitize_context(context))
       |> Map.put(:diagnostics, diagnostics)}
    end
  end

  def resolve(key, _context \\ %{}) when is_binary(key) do
    key = canonical_key(key)

    with {:ok, settings, user_settings} <- Store.resolved_settings() do
      if Schema.known_key?(key) do
        {:ok, resolved_setting(key, Schema.get_dotted(settings, key), settings, user_settings)}
      else
        {:error, :not_found}
      end
    end
  end

  def explain(key, context \\ %{}), do: resolve(key, context)

  def validate(settings_or_key_value, opts \\ [])

  def validate({key, value}, opts) when is_binary(key) do
    key = canonical_key(key)
    settings = Keyword.get(opts, :settings, defaults())
    Schema.validate_key_value(key, value, settings)
  end

  def validate(settings, opts) when is_map(settings), do: Schema.validate_settings(settings, opts)

  def list_provider_profiles do
    with {:ok, settings, _user_settings} <- Store.resolved_settings() do
      settings
      |> Map.get("providers", %{})
      |> Enum.map(fn {name, attrs} -> provider_profile(name, attrs) end)
      |> Enum.sort_by(& &1.name)
      |> then(&{:ok, &1})
    end
  end

  def list_model_profiles do
    with {:ok, settings, _user_settings} <- Store.resolved_settings() do
      settings
      |> Map.get("model_profiles", %{})
      |> Enum.map(fn {name, attrs} -> model_profile(name, attrs, settings) end)
      |> Enum.sort_by(& &1.name)
      |> then(&{:ok, &1})
    end
  end

  def resolve_model_profile(name, _context \\ %{}) when is_binary(name) do
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         {:ok, attrs} <- fetch_named(settings, "model_profiles", name) do
      {:ok, model_profile(name, attrs, settings)}
    end
  end

  def resolve_provider_profile(name, _context \\ %{}) when is_binary(name) do
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         {:ok, attrs} <- fetch_named(settings, "providers", name) do
      {:ok, provider_profile(name, attrs)}
    end
  end

  defp provider_profile(name, attrs) do
    api_key_ref = Map.get(attrs, "api_key_ref")

    %{
      name: name,
      type: Map.get(attrs, "type"),
      enabled: Map.get(attrs, "enabled", false),
      endpoint_kind: endpoint_kind(name, attrs),
      base_url: Map.get(attrs, "base_url"),
      api_key_ref: api_key_ref,
      credential_status: secret_status(api_key_ref)
    }
  end

  defp model_profile(name, attrs, settings) do
    provider = Map.get(attrs, "provider")
    provider_attrs = get_in(settings, ["providers", provider]) || %{}
    api_key_ref = Map.get(provider_attrs, "api_key_ref")

    %{
      name: name,
      provider: provider,
      provider_type: Map.get(provider_attrs, "type"),
      provider_enabled: Map.get(provider_attrs, "enabled", false),
      provider_endpoint_kind: endpoint_kind(provider, provider_attrs),
      provider_base_url: Map.get(provider_attrs, "base_url"),
      provider_api_key_ref: api_key_ref,
      model: Map.get(attrs, "model"),
      aliases: Map.get(attrs, "aliases", []),
      temperature: Map.get(attrs, "temperature"),
      max_tokens: Map.get(attrs, "max_tokens"),
      timeout_ms: Map.get(attrs, "timeout_ms"),
      credential_status: secret_status(api_key_ref)
    }
  end

  defp secret_status(nil), do: :missing
  defp secret_status(ref), do: Secrets.status(ref)

  defp endpoint_kind("local_ollama", attrs),
    do: Map.get(attrs, "endpoint_kind") || "local_endpoint"

  defp endpoint_kind(_name, attrs), do: Map.get(attrs, "endpoint_kind") || "credentialed_remote"

  defp resolved_setting(key, value, _settings, user_settings) do
    default_value = Schema.get_dotted(defaults(), key)
    operator_value = Schema.get_dotted(user_settings, key)
    source = if is_nil(operator_value), do: :default, else: :operator

    %{
      key: key,
      value: Secrets.redact(key, value),
      source: source,
      writable?: Schema.safe_write_key?(key),
      sensitive?: Schema.sensitive_key?(key),
      layers: layers(default_value, operator_value),
      diagnostics: [],
      namespace: key |> String.split(".", parts: 2) |> List.first()
    }
  end

  defp layers(default_value, nil), do: [%{source: :default, value: default_value}]

  defp layers(default_value, operator_value) do
    [
      %{source: :default, value: default_value},
      %{source: :operator, value: operator_value}
    ]
  end

  defp flatten(map), do: flatten(map, [])

  defp flatten(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> flatten(value, prefix ++ [key]) end)
  end

  defp flatten(value, prefix), do: [{Enum.join(prefix, "."), value}]

  defp fetch_named(settings, namespace, name) do
    case get_in(settings, [namespace, name]) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _other -> {:error, :not_found}
    end
  end

  defp namespace(opts) when is_list(opts), do: Keyword.get(opts, :namespace)
  defp namespace(namespace) when is_binary(namespace), do: namespace
  defp namespace(_namespace), do: nil

  defp canonical_key(key), do: Map.get(@legacy_key_aliases, key, key)

  defp sanitize_context(context) when is_map(context) do
    Map.drop(context, [:secret, "secret", :api_key, "api_key", :token, "token"])
  end

  defp post_write_diagnostics("memory.review_cadence", value, context) do
    case ReviewCadence.sync(value, context) do
      {:ok, diagnostic} -> [diagnostic]
      {:error, reason} -> [%{source: :memory_review_cadence, error: inspect(reason)}]
    end
  rescue
    exception ->
      [
        %{
          source: :memory_review_cadence,
          error: Exception.message(exception),
          kind: exception.__struct__
        }
      ]
  end

  defp post_write_diagnostics(_key, _value, _context), do: []
end
