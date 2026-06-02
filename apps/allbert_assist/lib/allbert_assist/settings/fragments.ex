defmodule AllbertAssist.Settings.Fragments do
  @moduledoc """
  Settings schema-fragment registry facade.

  This module assembles the existing Settings Central schema from fragment
  owners. It is a discovery/composition path only: fragments do not grant write
  authority, permissions, routes, or secret access.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema

  @composition_cache_key {__MODULE__, :default_composition}

  @type source :: :core | :app | :plugin

  @spec registered_fragments(keyword()) :: [Fragment.t()]
  def registered_fragments(opts \\ []), do: composition(opts).fragments

  @spec schema(keyword()) :: %{String.t() => map()}
  def schema(opts \\ []), do: composition(opts).schema

  @spec defaults(keyword()) :: map()
  def defaults(opts \\ []), do: composition(opts).defaults

  @spec safe_write_keys(keyword()) :: [String.t()]
  def safe_write_keys(opts \\ []), do: composition(opts).safe_write_keys

  @doc false
  def clear_cache do
    :persistent_term.erase(@composition_cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec fragment_for_key(String.t(), keyword()) :: {:ok, Fragment.t()} | {:error, :not_found}
  def fragment_for_key(key, opts \\ []) when is_binary(key) do
    opts
    |> registered_fragments()
    |> Enum.find(fn fragment -> Map.has_key?(fragment.schema, key) end)
    |> case do
      nil -> {:error, :not_found}
      fragment -> {:ok, fragment}
    end
  end

  @spec core_fragments() :: [Fragment.t()]
  def core_fragments do
    Schema.core_schema()
    |> Enum.group_by(fn {key, _schema} -> namespace(key) end)
    |> Enum.map(fn {namespace, entries} ->
      schema = Map.new(entries)
      defaults = namespace_defaults(namespace, Schema.core_defaults())

      Fragment.new!(%{
        id: "core:#{namespace}",
        owner: namespace,
        source: :core,
        group: namespace,
        schema: schema,
        defaults: defaults,
        safe_write_keys: namespace_safe_write_keys(namespace, Schema.core_safe_write_keys()),
        metadata: %{label: titleize(namespace)}
      })
    end)
    |> Enum.sort_by(& &1.id)
  end

  @spec app_fragments(keyword()) :: [Fragment.t()]
  def app_fragments(opts \\ []) do
    opts
    |> app_entries()
    |> Enum.map(fn app ->
      schema = Schema.normalize_app_schema_entries(Map.get(app, :settings_schema, []))

      Fragment.new!(%{
        id: "app:#{app.app_id}",
        owner: app.app_id,
        source: :app,
        group: :apps,
        schema: schema,
        defaults: defaults_from_schema(schema),
        safe_write_keys: safe_write_keys_from_schema(schema),
        metadata: %{display_name: Map.get(app, :display_name)}
      })
    end)
    |> Enum.reject(&empty_fragment?/1)
  end

  @spec plugin_fragments(keyword()) :: [Fragment.t()]
  def plugin_fragments(opts \\ []) do
    opts
    |> plugin_entries()
    |> Enum.map(fn plugin ->
      schema = Schema.normalize_plugin_schema_entries(plugin.settings_schema)

      Fragment.new!(%{
        id: "plugin:#{plugin.plugin_id}",
        owner: plugin.plugin_id,
        source: :plugin,
        group: :plugins,
        schema: schema,
        defaults: defaults_from_schema(schema),
        safe_write_keys: safe_write_keys_from_schema(schema),
        metadata: %{
          display_name: plugin.display_name,
          trust_status: plugin.trust_status,
          source: plugin.source
        }
      })
    end)
    |> Enum.reject(&empty_fragment?/1)
  end

  defp composition([]) do
    case :persistent_term.get(@composition_cache_key, nil) do
      nil ->
        composition = build_composition([])
        :persistent_term.put(@composition_cache_key, composition)
        composition

      composition ->
        composition
    end
  end

  defp composition(opts), do: build_composition(opts)

  defp build_composition(opts) do
    app_fragments = app_fragments(opts)
    plugin_fragments = plugin_fragments(opts)
    fragments = core_fragments() ++ app_fragments ++ plugin_fragments

    %{
      fragments: fragments,
      schema:
        plugin_fragments
        |> schema_from_fragments()
        |> Map.merge(schema_from_fragments(app_fragments))
        |> Map.merge(Schema.core_schema()),
      defaults:
        plugin_fragments
        |> defaults_from_fragments()
        |> deep_merge(defaults_from_fragments(app_fragments))
        |> deep_merge(Schema.core_defaults()),
      safe_write_keys:
        (Schema.core_safe_write_keys() ++
           Enum.flat_map(app_fragments, & &1.safe_write_keys) ++
           Enum.flat_map(plugin_fragments, & &1.safe_write_keys))
        |> Enum.uniq()
    }
  end

  defp schema_from_fragments(fragments) do
    Enum.reduce(fragments, %{}, fn fragment, acc -> Map.merge(acc, fragment.schema) end)
  end

  defp defaults_from_fragments(fragments) do
    Enum.reduce(fragments, %{}, fn fragment, acc -> deep_merge(acc, fragment.defaults) end)
  end

  defp defaults_from_schema(schema) do
    Enum.reduce(schema, %{}, fn {key, entry}, defaults ->
      Schema.put_dotted(defaults, key, Map.fetch!(entry, :default))
    end)
  end

  defp safe_write_keys_from_schema(schema) do
    schema
    |> Enum.filter(fn {_key, entry} -> Map.get(entry, :writable?, true) end)
    |> Enum.map(fn {key, _entry} -> key end)
  end

  defp namespace_defaults(namespace, defaults) do
    case Map.fetch(defaults, namespace) do
      {:ok, value} -> %{namespace => value}
      :error -> %{}
    end
  end

  defp namespace_safe_write_keys(namespace, keys) do
    prefix = namespace <> "."

    Enum.filter(keys, fn key -> key == namespace or String.starts_with?(key, prefix) end)
  end

  defp app_entries(opts) do
    opts
    |> Keyword.get(:app, [])
    |> AppRegistry.registered_apps()
  end

  defp plugin_entries(opts) do
    opts
    |> Keyword.get(:plugin, [])
    |> PluginRegistry.registered_plugins()
  end

  defp empty_fragment?(%Fragment{schema: schema}), do: map_size(schema) == 0

  defp namespace(key) do
    key
    |> String.split(".", parts: 2)
    |> List.first()
  end

  defp titleize(namespace) do
    namespace
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
