defmodule AllbertAssist.DevGates.V14M0RegistryLedger do
  @moduledoc """
  Deterministic v1.4 M0 baseline for the shipped registry composition.

  This is release-development evidence. It reads public registry projections,
  normalizes volatile runtime values, and binds the resulting element-level
  ledger with canonical JSON. It never reads settings values or secrets.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Bootstrap, as: AppBootstrap
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Fragments

  @schema_version 1
  @normalization "v14_m0_registry_ledger_v1"
  @generator_command "ALLBERT_HOME=<TEMP_HOME> MIX_ENV=test mix do allbert.ecto.migrate --quiet + run -e 'AllbertAssist.DevGates.V14M0RegistryLedger.write_frozen!()'"
  @temporary_plugin_registry :v14_m0_temporary_plugin_registry
  @temporary_plugin_table :v14_m0_temporary_plugin_registry_table
  @temporary_actions_overlay :v14_m0_temporary_actions_overlay
  @temporary_app_registry :v14_m0_temporary_app_registry
  @temporary_app_table :v14_m0_temporary_app_registry_table

  @doc "Return the repository-owned frozen v1.4 M0 fixture path."
  @spec fixture_path() :: Path.t()
  def fixture_path do
    Path.expand("../../../test/fixtures/v1.4/m0_registry_ledger.json", __DIR__)
  end

  @doc "Build the normalized live registry snapshot."
  def snapshot do
    :ok = AppBootstrap.await_ready()

    payload =
      %{
        "actions" => actions_snapshot(),
        "settings" => settings_snapshot(),
        "plugins" => plugins_snapshot(),
        "apps" => apps_snapshot(),
        "extensions" => extensions_snapshot(),
        "explicit_server_parity" => explicit_server_parity(),
        "isolated_mutation_diagnostics" => isolated_mutation_snapshot()
      }
      |> normalize()

    %{
      "schema_version" => @schema_version,
      "normalization" => @normalization,
      "payload" => payload,
      "digests" => payload_digests(payload)
    }
  end

  @doc "Return the lowercase SHA-256 of canonical normalized JSON."
  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> normalize()
    |> CanonicalJSON.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Load and self-validate the immutable element-level M0 fixture."
  def load_frozen! do
    frozen =
      case fixture_path() |> File.read!() |> Jason.decode!() do
        %{} = decoded -> decoded
        _other -> raise "invalid v1.4 M0 registry ledger fixture"
      end

    valid? =
      frozen["schema_version"] == @schema_version and
        frozen["normalization"] == @normalization and
        is_map(frozen["payload"]) and
        frozen["digests"] == payload_digests(frozen["payload"])

    if valid?, do: frozen, else: raise("invalid v1.4 M0 registry ledger fixture")
  end

  @doc "Fail when the current public registry composition differs from frozen M0."
  @spec check!() :: :ok
  def check! do
    frozen = load_frozen!()
    live = snapshot()

    if Map.drop(frozen, ["provenance"]) == live do
      :ok
    else
      raise "v1.4 M0 registry ledger drift: " <>
              "frozen=#{frozen["digests"]["payload_sha256"]} " <>
              "live=#{live["digests"]["payload_sha256"]}"
    end
  end

  @doc "Regenerate the immutable fixture at the current Git SHA."
  def write_frozen!(path \\ fixture_path()) do
    frozen =
      snapshot()
      |> Map.put("provenance", %{
        "source_sha" => source_sha!(),
        "generator_command" => @generator_command
      })

    path |> Path.dirname() |> File.mkdir_p!()

    encoded =
      frozen
      |> CanonicalJSON.encode()
      |> Jason.Formatter.pretty_print()
      |> Kernel.<>("\n")

    File.write!(path, encoded)
    frozen
  end

  @doc "Compare default registry reads with the same public calls using explicit servers."
  @spec explicit_server_parity() :: %{String.t() => boolean()}
  def explicit_server_parity do
    actions_opts = [
      app: [server: AppRegistry],
      plugin: [server: PluginRegistry],
      actions_overlay: ActionsOverlay
    ]

    %{
      "actions" =>
        normalize(ActionsRegistry.capabilities()) ==
          normalize(ActionsRegistry.capabilities(actions_opts)),
      "apps" =>
        normalize(AppRegistry.registered_apps()) ==
          normalize(AppRegistry.registered_apps(server: AppRegistry)),
      "plugins" =>
        normalize(PluginRegistry.registered_plugins()) ==
          normalize(PluginRegistry.registered_plugins(server: PluginRegistry)),
      "extensions" =>
        normalize(ExtensionsRegistry.contributions()) ==
          normalize(
            ExtensionsRegistry.contributions(
              app: [server: AppRegistry],
              plugin: [server: PluginRegistry]
            )
          ),
      "settings" =>
        normalize(Fragments.registered_fragments()) ==
          normalize(
            Fragments.registered_fragments(
              app: [server: AppRegistry],
              plugin: [server: PluginRegistry]
            )
          )
    }
  end

  defp payload_digests(payload) do
    payload
    |> Map.new(fn {section, rows} -> {section <> "_sha256", digest(rows)} end)
    |> Map.put("payload_sha256", digest(payload))
  end

  defp actions_snapshot do
    modules = ActionsRegistry.modules()

    static_modules = with_empty_action_sources(&ActionsRegistry.modules/1)

    dynamic_modules = ActionsOverlay.modules()
    plugin_modules = modules -- (static_modules -- dynamic_modules)

    definitions = compiled_action_definitions()

    {rows, input_schemas, output_schemas} =
      ActionsRegistry.capabilities()
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{}, %{}}, fn {capability, index}, {rows, inputs, outputs} ->
        module = capability.module
        input_schema = normalize(exported_value(module, :schema))
        output_schema = normalize(exported_value(module, :output_schema))
        input_digest = digest(input_schema)
        output_digest = digest(output_schema)

        row =
          %{
            "index" => index,
            "name" => capability.name,
            "module" => module_name(module),
            "source_bucket" =>
              action_source(module, static_modules, plugin_modules, dynamic_modules),
            "capability" =>
              capability
              |> Map.from_struct()
              |> Map.drop([:name, :module]),
            "input_schema_sha256" => input_digest,
            "output_schema_sha256" => output_digest
          }

        {
          [row | rows],
          Map.put_new(inputs, input_digest, input_schema),
          Map.put_new(outputs, output_digest, output_schema)
        }
      end)

    %{
      "rows" => Enum.reverse(rows),
      "input_schema_catalog" => input_schemas,
      "output_schema_catalog" => output_schemas,
      "agent_modules" => ActionsRegistry.agent_modules(),
      "internal_modules" => Enum.map(ActionsRegistry.internal_capabilities(), & &1.module),
      "duplicate_names" => ActionsRegistry.duplicate_names(),
      "diagnostics" => ActionsRegistry.diagnostics(),
      "compiled_definitions" => definitions,
      "definition_completeness" => %{
        "compiled" => length(definitions),
        "missing_from_registry" => definitions -- modules,
        "registry_missing_definition" => modules -- definitions
      },
      "counts" => %{
        "total" => length(modules),
        "static" => length(static_modules),
        "plugin_append" => length(plugin_modules),
        "dynamic_overlay" => length(dynamic_modules),
        "agent" => length(ActionsRegistry.agent_modules()),
        "internal" => length(ActionsRegistry.internal_capabilities())
      }
    }
  end

  defp settings_snapshot do
    fragments = Fragments.registered_fragments()
    schema = Fragments.schema()
    safe_write_rows = Fragments.safe_write_keys()
    safe_write_keys = safe_write_rows |> Enum.uniq() |> Enum.sort()

    writable_keys =
      schema
      |> Enum.filter(fn {_key, entry} -> Map.get(entry, :writable?, true) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    safe_and_writable_keys =
      MapSet.intersection(MapSet.new(safe_write_keys), MapSet.new(writable_keys))
      |> MapSet.to_list()
      |> Enum.sort()

    %{
      "fragments" =>
        fragments
        |> Enum.with_index(1)
        |> Enum.map(fn {fragment, index} ->
          fragment
          |> Map.from_struct()
          |> Map.put(:index, index)
        end),
      "effective_keys" => schema |> Map.keys() |> Enum.sort(),
      "effective_schema_sha256" => digest(schema),
      "effective_defaults_sha256" => digest(Fragments.defaults()),
      "safe_write_rows" => safe_write_rows,
      "safe_write_unique_keys" => safe_write_keys,
      "writable_effective_keys" => writable_keys,
      "safe_and_writable_effective_keys" => safe_and_writable_keys,
      "raw_app_schema" =>
        Enum.map(AppRegistry.registered_apps(), fn app ->
          %{"app_id" => app.app_id, "schema" => Map.get(app, :settings_schema, [])}
        end),
      "raw_plugin_schema" =>
        Enum.map(PluginRegistry.registered_plugins(), fn plugin ->
          %{"plugin_id" => plugin.plugin_id, "schema" => plugin.settings_schema}
        end),
      "counts" => %{
        "fragments" => length(fragments),
        "effective_keys" => map_size(schema),
        "safe_write_rows" => length(safe_write_rows),
        "safe_write_unique_keys" => length(safe_write_keys),
        "writable_effective_keys" => length(writable_keys),
        "safe_and_writable_effective_keys" => length(safe_and_writable_keys),
        "raw_app_rows" => length(AppRegistry.registered_settings_schema()),
        "raw_plugin_rows" => length(PluginRegistry.registered_settings_schema())
      }
    }
  end

  defp plugins_snapshot do
    entries = PluginRegistry.registered_plugins()

    %{
      "entries" =>
        entries
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, index} -> plugin_entry_snapshot(entry, index) end),
      "lookup_matches_entry" =>
        Enum.map(entries, fn entry ->
          %{
            "plugin_id" => entry.plugin_id,
            "matches" => PluginRegistry.lookup(entry.plugin_id) == {:ok, entry}
          }
        end),
      "apps" => PluginRegistry.registered_apps(),
      "channels" => Enum.map(PluginRegistry.registered_channels(), &channel_reference/1),
      "actions" => PluginRegistry.registered_actions(),
      "skill_paths" => PluginRegistry.registered_skill_paths(),
      "settings_keys" =>
        Enum.flat_map(entries, fn entry ->
          Enum.map(entry.settings_schema, fn row ->
            %{"plugin_id" => entry.plugin_id, "key" => field(row, :key)}
          end)
        end),
      "child_specs" =>
        Enum.map(PluginRegistry.registered_child_specs(), fn contribution ->
          spec = Supervisor.child_spec(contribution.child_spec, [])

          %{
            "plugin_id" => contribution.plugin_id,
            "id" => spec.id,
            "start" => spec.start,
            "type" => spec.type
          }
        end),
      "diagnostics" => PluginRegistry.diagnostics()
    }
  end

  defp apps_snapshot do
    entries = AppRegistry.registered_apps()

    %{
      "entries" =>
        entries
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, index} -> app_entry_snapshot(entry, index) end),
      "lookup_matches_entry" =>
        Enum.map(entries, fn entry ->
          looked_up =
            case AppRegistry.lookup(entry.app_id) do
              {:ok, found} -> stable_app_entry(found)
              other -> other
            end

          %{
            "app_id" => entry.app_id,
            "matches" => looked_up == stable_app_entry(entry)
          }
        end),
      "surfaces" => Enum.map(AppRegistry.registered_surfaces(), &surface_reference/1),
      "agents" => AppRegistry.registered_agents(),
      "signals" => AppRegistry.registered_signals(),
      "settings_keys" =>
        Enum.flat_map(entries, fn entry ->
          Enum.map(Map.get(entry, :settings_schema, []), fn row ->
            %{"app_id" => entry.app_id, "key" => field(row, :key)}
          end)
        end),
      "memory_namespaces" => AppRegistry.registered_memory_namespaces(),
      "surface_providers" =>
        Enum.map(AppRegistry.registered_surface_providers(), &surface_provider_reference/1),
      "skill_paths" => AppRegistry.registered_skill_paths(),
      "actions_by_app" =>
        Enum.map(entries, fn entry ->
          %{"app_id" => entry.app_id, "actions" => AppRegistry.actions_for(entry.app_id)}
        end),
      "diagnostics" => AppRegistry.diagnostics()
    }
  end

  defp extensions_snapshot do
    %{
      "apps" => Enum.map(ExtensionsRegistry.registered_apps(), & &1.app_id),
      "plugins" => Enum.map(ExtensionsRegistry.registered_plugins(), & &1.plugin_id),
      "surfaces" => Enum.map(ExtensionsRegistry.registered_surfaces(), &surface_reference/1),
      "surface_providers" =>
        Enum.map(ExtensionsRegistry.registered_surface_providers(), &surface_provider_reference/1),
      "intent_descriptors" => ExtensionsRegistry.registered_intent_descriptors(),
      "actions" => ExtensionsRegistry.registered_actions(),
      "skill_paths" => ExtensionsRegistry.registered_skill_paths(),
      "settings_schema" =>
        Enum.map(ExtensionsRegistry.registered_settings_schema(), fn row ->
          %{"key" => field(row, :key), "row_sha256" => digest(row)}
        end),
      "child_specs" =>
        Enum.map(ExtensionsRegistry.registered_child_specs(), fn contribution ->
          spec = Supervisor.child_spec(contribution.child_spec, [])
          %{"plugin_id" => contribution.plugin_id, "id" => spec.id}
        end),
      "diagnostics" => ExtensionsRegistry.diagnostics()
    }
  end

  defp plugin_entry_snapshot(entry, index) do
    entry
    |> Map.from_struct()
    |> Map.delete(:settings_schema)
    |> Map.put(:settings_keys, Enum.map(entry.settings_schema, &field(&1, :key)))
    |> Map.put(:index, index)
  end

  defp app_entry_snapshot(entry, index) do
    entry
    |> stable_app_entry()
    |> Map.delete(:settings_schema)
    |> Map.put(:settings_keys, Enum.map(Map.get(entry, :settings_schema, []), &field(&1, :key)))
    |> Map.put(:index, index)
  end

  defp stable_app_entry(entry) do
    entry
    |> Map.drop([:child_pid, :registered_at_ms])
  end

  defp channel_reference(channel) do
    child_spec = Supervisor.child_spec(field(channel, :child_spec), [])

    %{
      "plugin_id" => field(channel, :plugin_id),
      "channel_id" => field(channel, :channel_id),
      "status" => field(channel, :status),
      "child_id" => child_spec.id,
      "row_sha256" => digest(channel)
    }
  end

  defp surface_reference(surface) do
    %{
      "app_id" => field(surface, :app_id),
      "id" => field(surface, :id),
      "path" => field(surface, :path),
      "kind" => field(surface, :kind),
      "status" => field(surface, :status),
      "row_sha256" => digest(surface)
    }
  end

  defp surface_provider_reference(provider) do
    %{
      "app_id" => field(provider, :app_id),
      "module" => field(provider, :module),
      "surfaces" => Enum.map(field(provider, :surfaces) || [], &surface_reference/1),
      "catalog_sha256" => digest(field(provider, :catalog) || [])
    }
  end

  defp isolated_mutation_snapshot do
    with_isolated_registries(fn app_server, plugin_server, overlay_server ->
      context = [
        app: [server: app_server],
        plugin: [server: plugin_server],
        actions_overlay: overlay_server
      ]

      initial = isolated_counts(context)

      action_collision =
        ActionsOverlay.register_many(
          [
            %{
              name: DirectAnswer.name(),
              module: DirectAnswer,
              slug: "v14-m0-collision",
              revision: "1",
              exposure: :agent
            }
          ],
          server: overlay_server,
          existing_names: ActionsRegistry.names(context)
        )

      plugin_registration =
        PluginRegistry.register_module(AllbertAssist.Plugins.Telegram,
          server: plugin_server,
          side_effects: false
        )

      plugin_duplicate =
        PluginRegistry.register_module(AllbertAssist.Plugins.Telegram,
          server: plugin_server,
          side_effects: false
        )

      app_registration =
        AppRegistry.register(AllbertAssist.App.CoreApp,
          server: app_server,
          side_effects: false
        )

      app_duplicate =
        AppRegistry.register(AllbertAssist.App.CoreApp,
          server: app_server,
          side_effects: false
        )

      mutated = %{
        "counts" => isolated_counts(context),
        "action_collision" => action_collision,
        "action_diagnostics" => ActionsOverlay.diagnostics(overlay_server),
        "plugin_registration" => plugin_registration,
        "plugin_duplicate" => plugin_duplicate,
        "plugin_lookup" =>
          case PluginRegistry.lookup("allbert.telegram", server: plugin_server) do
            {:ok, entry} ->
              %{
                "status" => "ok",
                "plugin_id" => entry.plugin_id,
                "entry_sha256" => digest(entry)
              }

            other ->
              other
          end,
        "plugin_diagnostics" => PluginRegistry.diagnostics(server: plugin_server),
        "app_registration" => app_registration,
        "app_duplicate" => app_duplicate,
        "app_lookup" =>
          case AppRegistry.lookup(:allbert, server: app_server) do
            {:ok, entry} ->
              %{
                "status" => "ok",
                "app_id" => entry.app_id,
                "entry_sha256" => digest(stable_app_entry(entry))
              }

            other ->
              other
          end,
        "app_diagnostics" => AppRegistry.diagnostics(server: app_server)
      }

      :ok = ActionsOverlay.clear(server: overlay_server)
      :ok = PluginRegistry.clear(server: plugin_server, side_effects: false)
      :ok = AppRegistry.clear(server: app_server, side_effects: false)

      %{
        "initial" => initial,
        "mutated" => mutated,
        "cleared" => %{
          "counts" => isolated_counts(context),
          "action_diagnostics" => ActionsOverlay.diagnostics(overlay_server),
          "plugin_diagnostics" => PluginRegistry.diagnostics(server: plugin_server),
          "app_diagnostics" => AppRegistry.diagnostics(server: app_server)
        }
      }
    end)
  end

  defp isolated_counts(context) do
    contributions =
      ExtensionsRegistry.contributions(
        app: Keyword.fetch!(context, :app),
        plugin: Keyword.fetch!(context, :plugin)
      )

    %{
      "actions" => length(ActionsRegistry.modules(context)),
      "apps" => length(contributions.apps),
      "plugins" => length(contributions.plugins),
      "extensions_actions" => length(contributions.actions),
      "settings_fragments" => length(Fragments.registered_fragments(context))
    }
  end

  defp with_empty_action_sources(fun) when is_function(fun, 1) do
    with_temporary_plugin_and_overlay(fn plugin_server, overlay_server ->
      fun.(plugin: [server: plugin_server], actions_overlay: overlay_server)
    end)
  end

  defp with_isolated_registries(fun) when is_function(fun, 3) do
    with_temporary_plugin_and_overlay(fn plugin_server, overlay_server ->
      ensure_process_absent!(@temporary_app_registry)

      {:ok, app_pid} =
        AppRegistry.start_link(
          name: @temporary_app_registry,
          table_name: @temporary_app_table,
          enabled?: true
        )

      try do
        fun.(@temporary_app_registry, plugin_server, overlay_server)
      after
        stop_temporary(app_pid)
      end
    end)
  end

  defp with_temporary_plugin_and_overlay(fun) when is_function(fun, 2) do
    ensure_process_absent!(@temporary_plugin_registry)
    ensure_process_absent!(@temporary_actions_overlay)

    {:ok, plugin_pid} =
      PluginRegistry.start_link(
        name: @temporary_plugin_registry,
        table_name: @temporary_plugin_table,
        enabled?: true
      )

    try do
      {:ok, overlay_pid} = ActionsOverlay.start_link(name: @temporary_actions_overlay)

      try do
        fun.(@temporary_plugin_registry, @temporary_actions_overlay)
      after
        stop_temporary(overlay_pid)
      end
    after
      stop_temporary(plugin_pid)
    end
  end

  defp ensure_process_absent!(name) do
    if Process.whereis(name), do: raise("temporary registry already running: #{inspect(name)}")
  end

  defp stop_temporary(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  end

  defp compiled_action_definitions do
    repo_root()
    |> Path.join("_build/test/lib/*/ebin/*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case :beam_lib.chunks(String.to_charlist(path), [:attributes]) do
        {:ok, {module, _chunks}} -> [module]
        _other -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.filter(fn module ->
      Code.ensure_loaded?(module) and function_exported?(module, :allbert_action?, 0) and
        apply(module, :allbert_action?, []) == true
    end)
    |> Enum.sort_by(&module_name/1)
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp action_source(module, static_modules, plugin_modules, dynamic_modules) do
    cond do
      module in static_modules -> "static"
      module in plugin_modules -> "plugin_append"
      module in dynamic_modules -> "dynamic_overlay"
      true -> "unknown"
    end
  end

  defp exported_value(module, function) do
    if function_exported?(module, function, 0), do: apply(module, function, []), else: nil
  end

  defp normalize(nil), do: nil
  defp normalize(true), do: true
  defp normalize(false), do: false
  defp normalize(value) when is_integer(value) or is_float(value), do: value
  defp normalize(value) when is_binary(value), do: scrub_path(value)
  defp normalize(%Regex{} = regex), do: %{"$regex" => Regex.source(regex), "opts" => regex.opts}

  defp normalize(%MapSet{} = set),
    do: set |> MapSet.to_list() |> Enum.map(&normalize/1) |> Enum.sort()

  defp normalize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize()
    |> Map.put("$struct", module_name(struct.__struct__))
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {normalize_key(key), normalize(nested)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> normalize()}

  defp normalize(value) when is_function(value) do
    %{
      "$function" => module_name(:erlang.fun_info(value, :module) |> elem(1)),
      "name" => value |> :erlang.fun_info(:name) |> elem(1) |> Atom.to_string(),
      "arity" => value |> :erlang.fun_info(:arity) |> elem(1)
    }
  end

  defp normalize(value) when is_pid(value), do: "<PID>"
  defp normalize(value) when is_reference(value), do: "<REFERENCE>"
  defp normalize(value) when is_port(value), do: "<PORT>"
  defp normalize(value) when is_atom(value), do: atom_name(value)
  defp normalize(value), do: inspect(value)

  defp normalize_key(key) when is_binary(key), do: scrub_path(key)
  defp normalize_key(key) when is_atom(key), do: atom_name(key)
  defp normalize_key(key), do: key |> normalize() |> inspect()

  defp atom_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp module_name(module), do: atom_name(module)

  defp scrub_path(value) do
    value = String.replace(value, repo_root(), "<REPO_ROOT>")

    [Paths.home(), System.get_env("ALLBERT_HOME"), System.get_env("ALLBERT_HOME_DIR")]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(value, &String.replace(&2, &1, "<ALLBERT_HOME>"))
  end

  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  defp source_sha! do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: repo_root(), stderr_to_stdout: true) do
      {sha, 0} ->
        sha = String.trim(sha)

        if Regex.match?(~r/^[0-9a-f]{40}$/, sha),
          do: sha,
          else: raise("could not resolve v1.4 M0 source SHA")

      {_output, _status} ->
        raise "could not resolve v1.4 M0 source SHA"
    end
  end
end
