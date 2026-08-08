defmodule AllbertAssist.Settings.Fragments do
  @moduledoc """
  Settings schema-fragment registry facade.

  This module assembles the existing Settings Central schema from fragment
  owners. It is a discovery/composition path only: fragments do not grant write
  authority, permissions, routes, or secret access.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry

  alias AllbertAssist.Pack.{
    PathSegment,
    Projection,
    ProjectionProvider,
    Residual,
    ValidationDiagnostic
  }

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.{Fragment, FragmentOwner}
  alias AllbertAssist.Settings.Schema

  @composition_cache_key {__MODULE__, :default_composition}
  @composition_pin_key {__MODULE__, :pinned_composition}
  @composition_read_hook_key {__MODULE__, :composition_read_hook}

  @type source :: :core | :app | :plugin

  @spec registered_fragments(keyword()) :: [Fragment.t()]
  def registered_fragments(opts \\ []), do: composition(opts).fragments

  @spec schema(keyword()) :: %{String.t() => map()}
  def schema(opts \\ []), do: composition(opts).schema

  @spec defaults(keyword()) :: map()
  def defaults(opts \\ []), do: composition(opts).defaults

  @spec safe_write_keys(keyword()) :: [String.t()]
  def safe_write_keys(opts \\ []), do: composition(opts).safe_write_keys

  @doc "Return the Settings Central provenance bound to every composed key."
  @spec provenance(keyword()) :: %{String.t() => map()}
  def provenance(opts \\ []), do: composition(opts).provenance

  @doc "Validate that fragment identities and key ownership are globally unique."
  @spec validate_ownership([Fragment.t()]) :: :ok | {:error, term()}
  def validate_ownership(fragments) when is_list(fragments),
    do: validate_unique_ownership(fragments)

  def validate_ownership(value), do: {:error, {:invalid_settings_fragments, value}}

  @doc false
  def clear_cache do
    :persistent_term.erase(@composition_cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Run `fun` with ONE default-composition snapshot pinned to the calling process.

  A settings read-merge-validate pass (`Store.resolved_settings/0` and the
  Store write paths) reads the composition several times — fragments for the
  version contract, defaults for the merge, schema for validation. Each
  unpinned read hits the shared `persistent_term` cache, so an async
  registration-signal invalidation landing between two reads can hand ONE call
  two different compositions; validation then fails with
  `{:error, {:unknown_setting, _}}` against a transiently partial registry
  (v1.0.2 M8.3, root-caused in M8.2). Pinning takes a single snapshot per call.

  Reentrant: a nested call keeps the outer snapshot. Only default-composition
  reads (`opts == []`) are pinned; explicit-context reads are unaffected.
  """
  @spec with_composition((-> result)) :: result when result: term()
  def with_composition(fun) when is_function(fun, 0) do
    case Process.get(@composition_pin_key) do
      nil ->
        Process.put(@composition_pin_key, default_composition())

        try do
          fun.()
        after
          Process.delete(@composition_pin_key)
        end

      _pinned ->
        fun.()
    end
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
    FragmentOwner.fragments!("allbert_assist", :allbert_assist, Residual.settings_fragments())
  end

  @doc """
  Build settings fragments from sealed App/Plugin metadata entries.

  Unlike `registered_fragments/1`, this function never reads registries,
  process state, or the composition cache. Input order is retained after the
  sorted core-fragment prefix.
  """
  @spec candidate_fragments([map()], [map()]) ::
          {:ok, [Fragment.t()]} | {:error, [ValidationDiagnostic.t()]}
  def candidate_fragments(app_entries, plugin_entries)
      when is_list(app_entries) and is_list(plugin_entries) do
    with {:ok, closed} <- ProjectionProvider.closed() do
      candidate_fragments(closed, app_entries, plugin_entries)
    else
      _error -> {:error, [candidate_diagnostic(:settings_pack_projection_unavailable)]}
    end
  end

  def candidate_fragments(_app_entries, _plugin_entries),
    do: {:error, [candidate_diagnostic(:invalid_candidate_entries)]}

  @spec candidate_fragments(Projection.Closed.t(), [map()], [map()]) ::
          {:ok, [Fragment.t()]} | {:error, [ValidationDiagnostic.t()]}
  def candidate_fragments(%Projection.Closed{} = closed, app_entries, plugin_entries)
      when is_list(app_entries) and is_list(plugin_entries) do
    with {:ok, pack_contributions} <- pack_contributions(closed),
         {:ok, apps} <- app_fragments_from_entries(app_entries),
         {:ok, plugins} <- plugin_fragments_from_entries(plugin_entries) do
      fragments = Enum.map(pack_contributions, & &1.fragment) ++ apps ++ plugins

      case validate_unique_ownership(fragments) do
        :ok -> {:ok, fragments}
        {:error, reason} -> {:error, [candidate_diagnostic(reason)]}
      end
    else
      {:error, [%ValidationDiagnostic{} | _diagnostics]} = error -> error
      {:error, reason} -> {:error, [candidate_diagnostic(reason)]}
    end
  end

  def candidate_fragments(_closed, _app_entries, _plugin_entries),
    do: {:error, [candidate_diagnostic(:invalid_candidate_entries)]}

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
      schema = Schema.normalize_plugin_schema_entries(plugin.settings_schema, plugin: plugin)

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
    case Process.get(@composition_pin_key) do
      nil -> default_composition()
      pinned -> pinned
    end
  end

  defp composition(opts), do: build_composition(opts)

  defp default_composition do
    read_hook()

    case :persistent_term.get(@composition_cache_key, nil) do
      nil ->
        composition = build_composition([])
        :persistent_term.put(@composition_cache_key, composition)
        composition

      composition ->
        composition
    end
  end

  # Test-only seam (v1.0.2 M8.3): fires before each default-composition cache
  # read so the composition-race regression test can swap the cache between two
  # reads deterministically. Production processes never set the hook; the
  # process-dictionary probe is effectively free.
  defp read_hook do
    case Process.get(@composition_read_hook_key) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp build_composition(opts) do
    pack_contributions = pack_contributions!(opts)
    pack_fragments = Enum.map(pack_contributions, & &1.fragment)
    app_fragments = app_fragments(opts)
    plugin_fragments = plugin_fragments(opts)
    fragments = pack_fragments ++ app_fragments ++ plugin_fragments

    case validate_unique_ownership(fragments) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid settings ownership: #{inspect(reason)}"
    end

    %{
      fragments: fragments,
      schema: schema_from_fragments(fragments),
      defaults:
        pack_contributions
        |> Enum.reduce(%{}, fn contribution, defaults ->
          deep_merge(defaults, contribution.defaults)
        end)
        |> deep_merge(defaults_from_fragments(app_fragments))
        |> deep_merge(defaults_from_fragments(plugin_fragments)),
      safe_write_keys:
        ((pack_contributions
          |> Enum.flat_map(& &1.safe_write_rows)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))) ++
           Enum.flat_map(app_fragments, & &1.safe_write_keys) ++
           Enum.flat_map(plugin_fragments, & &1.safe_write_keys))
        |> Enum.uniq(),
      provenance: provenance_from_fragments(pack_contributions, app_fragments, plugin_fragments)
    }
  end

  defp schema_from_fragments(fragments) do
    Enum.reduce(fragments, %{}, fn fragment, acc ->
      Map.merge(acc, fragment.schema, fn key, _left, _right ->
        raise ArgumentError, "duplicate settings key: #{key}"
      end)
    end)
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

  defp app_entries(opts) do
    opts
    |> Keyword.get(:app, [])
    |> AppRegistry.registered_apps()
  end

  defp app_fragments_from_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn app, {:ok, fragments} ->
      app_id = Map.get(app, :app_id)
      schema_entries = Map.get(app, :settings_schema, [])

      if is_atom(app_id) and is_list(schema_entries) do
        case Schema.normalize_app_schema_entries_checked(schema_entries) do
          {:ok, schema} ->
            fragment =
              Fragment.new!(%{
                id: "app:#{app_id}",
                owner: app_id,
                source: :app,
                group: :apps,
                schema: schema,
                defaults: defaults_from_schema(schema),
                safe_write_keys: safe_write_keys_from_schema(schema),
                metadata: %{display_name: Map.get(app, :display_name)}
              })

            {:cont,
             {:ok, if(empty_fragment?(fragment), do: fragments, else: [fragment | fragments])}}

          {:error, reason} ->
            {:halt, {:error, [candidate_diagnostic(reason)]}}
        end
      else
        {:halt, {:error, [candidate_diagnostic(:invalid_app_entry)]}}
      end
    end)
    |> reverse_candidate_fragments()
  rescue
    _exception -> {:error, [candidate_diagnostic(:invalid_app_settings_schema)]}
  end

  defp plugin_fragments_from_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn plugin, {:ok, fragments} ->
      plugin_id = Map.get(plugin, :plugin_id)
      schema_entries = Map.get(plugin, :settings_schema, [])

      if is_binary(plugin_id) and plugin_id != "" and is_list(schema_entries) do
        case Schema.normalize_plugin_schema_entries_checked(schema_entries, plugin: plugin) do
          {:ok, schema} ->
            fragment =
              Fragment.new!(%{
                id: "plugin:#{plugin_id}",
                owner: plugin_id,
                source: :plugin,
                group: :plugins,
                schema: schema,
                defaults: defaults_from_schema(schema),
                safe_write_keys: safe_write_keys_from_schema(schema),
                metadata: %{
                  display_name: Map.get(plugin, :display_name),
                  trust_status: Map.get(plugin, :trust_status),
                  source: Map.get(plugin, :source)
                }
              })

            {:cont,
             {:ok, if(empty_fragment?(fragment), do: fragments, else: [fragment | fragments])}}

          {:error, reason} ->
            {:halt, {:error, [candidate_diagnostic(reason)]}}
        end
      else
        {:halt, {:error, [candidate_diagnostic(:invalid_plugin_entry)]}}
      end
    end)
    |> reverse_candidate_fragments()
  rescue
    _exception -> {:error, [candidate_diagnostic(:invalid_plugin_settings_schema)]}
  end

  defp reverse_candidate_fragments({:ok, fragments}), do: {:ok, Enum.reverse(fragments)}
  defp reverse_candidate_fragments(error), do: error

  defp candidate_diagnostic(reason) do
    %ValidationDiagnostic{
      schema_version: 1,
      code: :invalid_value,
      path: [%PathSegment{schema_version: 1, kind: :field, value: "settings_schema"}],
      owner: nil,
      detail: %{reason: reason}
    }
  end

  defp plugin_entries(opts) do
    opts
    |> Keyword.get(:plugin, [])
    |> PluginRegistry.registered_plugins()
  end

  defp pack_contributions!(opts) do
    result =
      case Keyword.fetch(opts, :pack_projection) do
        {:ok, %Projection.Closed{} = closed} ->
          pack_contributions(closed)

        {:ok, invalid} ->
          raise ArgumentError, "invalid Settings Pack projection: #{inspect(invalid)}"

        :error ->
          default_pack_contributions()
      end

    case result do
      {:ok, contributions} ->
        contributions

      {:error, reason} ->
        raise ArgumentError, "invalid Settings Pack contribution: #{inspect(reason)}"
    end
  end

  # An owner application must boot without adding upward dependencies merely to
  # discover settings. Source/test owner CWDs can therefore lack one or more
  # applications from the complete four-application release closure even when a
  # shared build directory happens to make composition BEAMs visible. Only that
  # typed source-closure absence selects the residual declaration. A packaged
  # runtime and every other projection error remain fail-closed. Candidate
  # assembly always supplies its already-sealed complete projection.
  defp default_pack_contributions do
    case ProjectionProvider.closed() do
      {:ok, closed} ->
        pack_contributions(closed)

      {:error, {:application_metadata, _application, {:unknown_application, _missing}}} =
          error ->
        if source_owner_context?() do
          residual_pack_contributions()
        else
          error
        end

      error ->
        error
    end
  end

  defp residual_pack_contributions do
    FragmentOwner.resolve_pack(
      "allbert_assist",
      :allbert_assist,
      Residual.settings_fragments()
    )
  end

  defp source_owner_context? do
    is_nil(System.get_env("RELEASE_ROOT")) and is_nil(System.get_env("RELEASE_VSN"))
  end

  defp pack_contributions(%Projection.Closed{rows: rows}) do
    rows
    |> Enum.sort_by(&{&1.registry_order, &1.id})
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, contributions} ->
      module = row.descriptor_module

      with true <- function_exported?(module, :settings_fragments, 0),
           owner_modules when is_list(owner_modules) <- module.settings_fragments(),
           {:ok, resolved} <- FragmentOwner.resolve_pack(row.id, row.application, owner_modules) do
        {:cont, {:ok, contributions ++ resolved}}
      else
        false ->
          {:halt, {:error, {:missing_settings_fragment_callback, row.id, module}}}

        value when not is_list(value) ->
          {:halt, {:error, {:invalid_settings_fragment_callback, row.id, value}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  rescue
    exception -> {:error, {:settings_fragment_callback_raised, exception.__struct__}}
  catch
    kind, reason -> {:error, {:settings_fragment_callback_caught, kind, reason}}
  end

  defp validate_unique_ownership(fragments) do
    with :ok <- unique_fragment_ids(fragments),
         :ok <- unique_fragment_keys(fragments) do
      :ok
    end
  end

  defp unique_fragment_ids(fragments) do
    fragments
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, owners} -> length(owners) > 1 end)
    |> case do
      nil -> :ok
      {id, owners} -> {:error, {:duplicate_settings_fragment_id, id, fragment_claims(owners)}}
    end
  end

  defp unique_fragment_keys(fragments) do
    fragments
    |> Enum.flat_map(fn fragment -> Enum.map(Map.keys(fragment.schema), &{&1, fragment}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.find(fn {_key, owners} -> length(owners) > 1 end)
    |> case do
      nil -> :ok
      {key, owners} -> {:error, {:duplicate_settings_key, key, fragment_claims(owners)}}
    end
  end

  defp fragment_claims(fragments) do
    Enum.map(fragments, &%{id: &1.id, owner: &1.owner, source: &1.source})
  end

  defp provenance_from_fragments(pack_contributions, app_fragments, plugin_fragments) do
    pack =
      Enum.reduce(pack_contributions, %{}, fn contribution, provenance ->
        fragment = contribution.fragment
        owner = pack_owner_metadata(contribution)

        provenance =
          Enum.reduce(Map.keys(fragment.schema), provenance, fn key, acc ->
            Map.put(acc, key, Map.put(owner, :kind, :schema))
          end)

        provenance =
          Enum.reduce(contribution.dynamic_default_rows, provenance, fn {key, declaration}, acc ->
            Map.put(
              acc,
              key,
              owner
              |> Map.put(:kind, :dynamic_default)
              |> Map.put(:declaration, declaration)
            )
          end)

        Enum.reduce(contribution.safe_write_rows, provenance, fn {_index, key}, acc ->
          case Map.fetch(acc, key) do
            {:ok, existing} ->
              Map.put(acc, key, Map.put(existing, :safe_write_declaration, key))

            :error ->
              kind = if String.contains?(key, "*"), do: :safe_write_pattern, else: :safe_write_key

              Map.put(
                acc,
                key,
                owner
                |> Map.put(:kind, kind)
                |> Map.put(:declaration, key)
              )
          end
        end)
      end)

    legacy =
      Enum.flat_map(app_fragments ++ plugin_fragments, fn fragment ->
        Enum.map(Map.keys(fragment.schema), fn key ->
          {key,
           %{
             fragment_id: fragment.id,
             owner: fragment.owner,
             source: fragment.source,
             pack_id: nil,
             application: nil,
             owner_module: nil,
             kind: :schema
           }}
        end)
      end)

    Map.merge(pack, Map.new(legacy))
  end

  defp pack_owner_metadata(contribution) do
    fragment = contribution.fragment

    %{
      fragment_id: fragment.id,
      owner: fragment.owner,
      source: fragment.source,
      pack_id: contribution.pack_id,
      application: contribution.application,
      owner_module: contribution.owner_module
    }
  end

  defp empty_fragment?(%Fragment{schema: schema}), do: map_size(schema) == 0

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
