defmodule AllbertAssist.Pack.CandidateBuilder.MetadataRows do
  @moduledoc """
  Pure metadata-derived row families for `CandidateBuilder`.

  This adapter deliberately receives immutable Registry snapshots and uses only
  the supplied-entry projections for settings and intents. It never observes a
  registry and never delegates assembly to `LegacyAdapter`.
  """

  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Pack.{ActionBinding, Row, RowSchemas, ValidationDiagnostic}
  alias AllbertAssist.Pack.CandidateBuilder.RowFamilies
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Plugin.Registry.MetadataSnapshot, as: PluginSnapshot
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments

  @residual_owner_id "allbert_assist"

  @spec build(Closed.t(), AppSnapshot.t(), PluginSnapshot.t(), keyword()) ::
          {:ok, RowFamilies.t()} | {:error, [ValidationDiagnostic.t()]}
  def build(
        %Closed{},
        %AppSnapshot{schema_version: 1, entries: apps},
        %PluginSnapshot{schema_version: 1, entries: plugins},
        opts
      )
      when is_list(apps) and is_list(plugins) and is_list(opts) do
    with {:ok, owners} <- owner_index(apps, plugins),
         {:ok, settings, surfaces, skills, intents} <-
           build_independent_families(apps, plugins, owners, opts),
         {:ok, bindings} <- binding_index(Keyword.get(opts, :action_bindings, [])),
         {:ok, app_rows} <-
           app_rows(
             apps,
             owners,
             bindings,
             settings.refs,
             surfaces.refs,
             skills.refs,
             intents.refs
           ) do
      %RowFamilies{} = families = RowFamilies.empty()

      {:ok,
       %{
         families
         | apps: app_rows,
           settings_fragments: settings.rows,
           surfaces: surfaces.rows,
           skill_roots: skills.rows,
           intent_descriptors: intents.rows
       }}
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      _ -> {:error, [diagnostic(:invalid_metadata_rows)]}
    end
  rescue
    _ -> {:error, [diagnostic(:invalid_metadata_rows)]}
  end

  def build(_closed, _apps, _plugins, _opts), do: {:error, [diagnostic(:invalid_metadata_input)]}

  defp build_independent_families(apps, plugins, owners, opts) do
    [
      fn ->
        with {:ok, fragments} <- settings_fragments(apps, plugins, opts),
             do: settings_rows(fragments, owners)
      end,
      fn -> surface_rows(apps, owners) end,
      fn -> skill_rows(apps, plugins) end,
      fn ->
        with {:ok, descriptors} <- intent_descriptors(apps, plugins, opts),
             do: intent_rows(descriptors, owners)
      end
    ]
    |> Task.async_stream(& &1.(),
      ordered: true,
      max_concurrency: 4,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
    |> case do
      [
        {:ok, {:ok, settings}},
        {:ok, {:ok, surfaces}},
        {:ok, {:ok, skills}},
        {:ok, {:ok, intents}}
      ] ->
        {:ok, settings, surfaces, skills, intents}

      results ->
        family_error(results)
    end
  end

  defp family_error(results) do
    Enum.find_value(results, {:error, [diagnostic(:metadata_capture_failed)]}, fn
      {:ok, {:error, diagnostics}} when is_list(diagnostics) -> {:error, diagnostics}
      _other -> nil
    end)
  end

  defp settings_fragments(apps, plugins, opts) do
    case Keyword.fetch(opts, :settings_fragments) do
      {:ok, fragments} when is_list(fragments) -> {:ok, fragments}
      :error -> SettingsFragments.candidate_fragments(apps, plugins)
      _ -> {:error, [diagnostic(:invalid_settings_fragments)]}
    end
  end

  defp intent_descriptors(apps, plugins, opts) do
    case Keyword.fetch(opts, :intent_descriptors) do
      {:ok, descriptors} when is_list(descriptors) -> {:ok, descriptors}
      :error -> ExtensionsRegistry.intent_descriptors_from_entries(apps, plugins)
      _ -> {:error, [diagnostic(:invalid_intent_descriptors)]}
    end
  end

  defp owner_index(apps, plugins) do
    enabled = Enum.filter(plugins, &(&1.status == :enabled))
    app_modules = Enum.map(apps, & &1.module)
    app_ids = Enum.map(apps, & &1.app_id)
    plugin_pairs = for plugin <- enabled, module <- plugin.apps, do: {module, plugin.plugin_id}
    plugin_modules = Enum.map(plugin_pairs, &elem(&1, 0))

    cond do
      length(Enum.uniq(app_modules)) != length(app_modules) ->
        invalid(:duplicate_app_module)

      length(Enum.uniq(app_ids)) != length(app_ids) ->
        invalid(:duplicate_app_id)

      length(Enum.uniq(plugin_modules)) != length(plugin_modules) ->
        invalid(:duplicate_plugin_app)

      not MapSet.subset?(MapSet.new(plugin_modules), MapSet.new(app_modules)) ->
        invalid(:dangling_plugin_app)

      true ->
        plugin_by_module = Map.new(plugin_pairs)

        by_module =
          Map.new(apps, &{&1.module, Map.get(plugin_by_module, &1.module, @residual_owner_id)})

        {:ok,
         %{
           by_module: by_module,
           by_app_id: Map.new(apps, &{&1.app_id, Map.fetch!(by_module, &1.module)}),
           app_id_by_module: Map.new(apps, &{&1.module, &1.app_id})
         }}
    end
  end

  defp settings_rows(fragments, owners) do
    fragments
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{rows: %{}, refs: %{}}}, fn {fragment, index}, {:ok, acc} ->
      with {:ok, owner_id} <- settings_owner(fragment, owners),
           {:ok, fragment_id} <- canonical_id(fragment.id),
           {:ok, source_owner_id} <- canonical_id(fragment.owner) do
        authority = %{
          "fragment_id" => fragment_id,
          "legacy_owner_id" => source_owner_id,
          "source" => fragment.source,
          "group" => fragment.group,
          "schema_version" => fragment.schema_version,
          "schema" => closed_value(fragment.schema),
          "defaults" => closed_value(fragment.defaults),
          "safe_write_keys" => fragment.safe_write_keys,
          "metadata" => closed_value(fragment.metadata)
        }

        normalized =
          reference!(
            :settings_fragment_ref_v1,
            %{
              "fragment_id" => fragment_id,
              "owner_id" => owner_id,
              "schema_version" => fragment.schema_version
            },
            authority,
            "projection_sha256"
          )

        payload = RowSchemas.canonical_projection(normalized)

        row =
          row(
            :settings_fragments,
            owner_id,
            :fragment_id,
            fragment_id,
            :legacy_index,
            index,
            :settings_fragment_ref_v1,
            payload,
            RowSchemas.source_authority_projection(normalized)
          )

        refs =
          if fragment.source == :app do
            Map.update(
              acc.refs,
              fragment.owner,
              [fragment_ref(payload)],
              &(&1 ++ [fragment_ref(payload)])
            )
          else
            acc.refs
          end

        {:cont, {:ok, %{rows: append(acc.rows, owner_id, row), refs: refs}}}
      else
        _ -> {:halt, invalid(:invalid_settings_fragment)}
      end
    end)
  end

  defp settings_owner(%{source: :core}, _owners), do: {:ok, @residual_owner_id}
  defp settings_owner(%{source: :plugin, owner: owner}, _owners), do: canonical_id(owner)

  defp settings_owner(%{source: :app, owner: app_id}, %{by_app_id: by_app_id}) do
    Map.fetch(by_app_id, app_id) |> map_fetch_result(:unknown_settings_app)
  end

  defp settings_owner(_fragment, _owners), do: invalid(:invalid_settings_owner)

  defp surface_rows(apps, owners) do
    if Enum.any?(apps, &(&1.surfaces != [])) do
      invalid(:legacy_surface_list_present)
    else
      apps
      |> Enum.flat_map(fn app -> Enum.map(app.provider_surfaces, &{app, &1}) end)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, %{rows: %{}, refs: %{}}}, fn {{app, surface}, index},
                                                              {:ok, acc} ->
        with true <- surface.app_id == app.app_id,
             {:ok, owner_id} <-
               Map.fetch(owners.by_module, app.module) |> map_fetch_result(:unknown_surface_app),
             {:ok, authority} <- surface_authority(surface) do
          normalized =
            reference!(
              :surface_ref_v1,
              %{
                "surface_id" => surface.id,
                "module" => module_name(app.surface_provider)
              },
              authority,
              "projection_sha256"
            )

          payload = RowSchemas.canonical_projection(normalized)
          surface_id = payload["surface_id"]

          row =
            row(
              :surfaces,
              owner_id,
              :surface_id,
              surface_id,
              :legacy_index,
              index,
              :surface_ref_v1,
              payload,
              RowSchemas.source_authority_projection(normalized)
            )

          ref = %{"surface_id" => surface_id, "projection_sha256" => payload["projection_sha256"]}

          {:cont,
           {:ok,
            %{
              rows: append(acc.rows, owner_id, row),
              refs: Map.update(acc.refs, app.app_id, [ref], &(&1 ++ [ref]))
            }}}
        else
          _ -> {:halt, invalid(:invalid_surface)}
        end
      end)
    end
  end

  defp surface_authority(%AllbertAssist.Surface{} = surface) do
    with {:ok, nodes} <- map_all(surface.nodes, &surface_node_authority/1) do
      {:ok,
       %{
         "id" => surface.id,
         "app_id" => surface.app_id,
         "label" => surface.label,
         "path" => surface.path,
         "kind" => surface.kind,
         "zone" => surface.zone,
         "status" => surface.status,
         "nodes" => nodes,
         "fallback_text" => surface.fallback_text,
         "metadata" => closed_value(surface.metadata)
       }}
    end
  end

  defp surface_authority(_), do: invalid(:invalid_surface_authority)

  defp surface_node_authority(%AllbertAssist.Surface.Node{} = node) do
    with {:ok, bindings} <- map_all(node.bindings, &surface_binding_authority/1),
         {:ok, children} <- map_all(node.children, &surface_node_authority/1) do
      {:ok,
       %{
         "id" => node.id,
         "component" => node.component,
         "props" => closed_value(node.props),
         "bindings" => bindings,
         "children" => children
       }}
    end
  end

  defp surface_node_authority(_), do: invalid(:invalid_surface_node)

  defp surface_binding_authority(%AllbertAssist.Surface.ActionBinding{} = binding),
    do:
      {:ok,
       %{
         "action_name" => binding.action_name,
         "action_module" => binding.action_module,
         "permission" => binding.permission,
         "app_id" => binding.app_id,
         "plugin_id" => binding.plugin_id,
         "confirmation_required?" => binding.confirmation_required?
       }}

  defp surface_binding_authority(_), do: invalid(:invalid_surface_binding)

  defp intent_rows(descriptors, owners) do
    descriptors
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{rows: %{}, refs: %{}}}, fn {descriptor, index}, {:ok, acc} ->
      with {:ok, registered_app_id} <-
             Map.fetch(owners.app_id_by_module, descriptor.source_module)
             |> map_fetch_result(:unknown_intent_module),
           true <- descriptor.app_id == registered_app_id,
           {:ok, owner_id} <-
             Map.fetch(owners.by_module, descriptor.source_module)
             |> map_fetch_result(:unknown_intent_owner),
           {:ok, authority} <- intent_authority(descriptor) do
        normalized =
          reference!(
            :intent_descriptor_ref_v1,
            %{
              "intent_id" => descriptor.id,
              "module" => module_name(descriptor.source_module)
            },
            authority,
            "projection_sha256"
          )

        payload = RowSchemas.canonical_projection(normalized)
        intent_id = payload["intent_id"]

        row =
          row(
            :intent_descriptors,
            owner_id,
            :intent_id,
            intent_id,
            :legacy_index,
            index,
            :intent_descriptor_ref_v1,
            payload,
            RowSchemas.source_authority_projection(normalized)
          )

        ref = %{"intent_id" => intent_id, "projection_sha256" => payload["projection_sha256"]}

        {:cont,
         {:ok,
          %{
            rows: append(acc.rows, owner_id, row),
            refs: Map.update(acc.refs, descriptor.app_id, [ref], &(&1 ++ [ref]))
          }}}
      else
        _ -> {:halt, invalid(:invalid_intent_descriptor)}
      end
    end)
  end

  defp intent_authority(%AllbertAssist.Intent.Descriptor{} = descriptor) do
    vocabulary = descriptor.vocabulary
    capability = descriptor.capability

    {:ok,
     %{
       "intent_id" => descriptor.id,
       "app_id" => descriptor.app_id,
       "action_name" => descriptor.action_name,
       "label" => descriptor.label,
       "source" => descriptor.source,
       "source_module" => descriptor.source_module,
       "destination" => descriptor.destination,
       "selection_policy" => descriptor.selection_policy,
       "examples" => descriptor.examples,
       "synonyms" => descriptor.synonyms,
       "required_slots" => descriptor.required_slots,
       "optional_slots" => descriptor.optional_slots,
       "slot_extractors" => descriptor.slot_extractors,
       "vocabulary" => %{
         "phrases" => field(vocabulary, :phrases, []),
         "negative_phrases" => field(vocabulary, :negative_phrases, []),
         "selection_phrases" => field(vocabulary, :selection_phrases, []),
         "selection_negative_phrases" => field(vocabulary, :selection_negative_phrases, []),
         "clarification_phrases" => field(vocabulary, :clarification_phrases, []),
         "allow_single_token_match" => field(vocabulary, :allow_single_token_match, true),
         "allow_required_slot_selection" =>
           field(vocabulary, :allow_required_slot_selection, false)
       },
       "handoff_required" => descriptor.handoff_required?,
       "routable_by_default" => descriptor.routable_by_default?,
       "capability" => %{
         "name" => field(capability, :name),
         "module" => field(capability, :module),
         "registered?" => field(capability, :registered?),
         "permission" => field(capability, :permission),
         "exposure" => field(capability, :exposure),
         "execution_mode" => field(capability, :execution_mode),
         "skill_backed?" => field(capability, :skill_backed?),
         "confirmation" => field(capability, :confirmation),
         "resumable?" => field(capability, :resumable?),
         "retry_safety" => field(capability, :retry_safety),
         "app_id" => field(capability, :app_id),
         "plugin_id" => field(capability, :plugin_id)
       }
     }}
  end

  defp intent_authority(_), do: invalid(:invalid_intent_authority)

  defp skill_rows(apps, plugins) do
    with :ok <- validate_skill_closure(apps, plugins) do
      plugins
      |> Enum.filter(&(&1.status == :enabled))
      |> Enum.reduce_while({:ok, %{rows: %{}, refs: %{}}}, fn plugin, {:ok, acc} ->
        case plugin_skill_rows(plugin, apps) do
          {:ok, rows, refs} ->
            {:cont,
             {:ok,
              %{
                rows: Map.put(acc.rows, plugin.plugin_id, rows),
                refs: Map.merge(acc.refs, refs, fn _, left, right -> left ++ right end)
              }}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp validate_skill_closure(apps, plugins) do
    enabled = Enum.filter(plugins, &(&1.status == :enabled))
    module_plugins = Enum.reject(enabled, &is_nil(&1.module))
    modules = Enum.flat_map(module_plugins, & &1.apps)

    cond do
      length(Enum.uniq(modules)) != length(modules) ->
        invalid(:duplicate_skill_app)

      Enum.any?(
        apps,
        &(&1.skill_paths != [] and
              Enum.count(module_plugins, fn plugin -> &1.module in plugin.apps end) != 1)
      ) ->
        invalid(:unowned_skill_app)

      Enum.all?(module_plugins, &matching_skill_paths?(&1, apps)) ->
        :ok

      true ->
        invalid(:invalid_skill_paths)
    end
  end

  defp matching_skill_paths?(plugin, apps) do
    app_paths =
      apps
      |> Enum.filter(&(&1.module in plugin.apps))
      |> Enum.flat_map(& &1.skill_paths)
      |> Enum.map(&Path.expand/1)

    plugin_paths = Enum.map(plugin.skill_paths, &Path.expand/1)
    app_paths == plugin_paths and length(Enum.uniq(plugin_paths)) == length(plugin_paths)
  end

  defp plugin_skill_rows(%{module: nil} = plugin, _apps), do: declared_skill_rows(plugin)

  defp plugin_skill_rows(plugin, apps) do
    plugin.skill_paths
    |> Enum.reduce_while({:ok, [], %{}, MapSet.new()}, fn path, {:ok, rows, refs, ids} ->
      with {:ok, relative_path} <- repository_skill_path(path),
           {:ok, app_id} <- skill_app_id(plugin, apps, path),
           root_id = "#{app_id}:#{Path.basename(relative_path)}",
           false <- MapSet.member?(ids, root_id) do
        {row, ref} = skill_row(plugin.plugin_id, plugin.trust_status, root_id, relative_path)

        {:cont,
         {:ok, rows ++ [row], Map.update(refs, app_id, [ref], &(&1 ++ [ref])),
          MapSet.put(ids, root_id)}}
      else
        _ -> {:halt, invalid(:invalid_skill_root)}
      end
    end)
    |> finalize_skill_rows()
  end

  defp declared_skill_rows(plugin) do
    plugin.skill_paths
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn path, {:ok, rows, ids} ->
      with {:ok, relative_path} <- declared_skill_path(plugin, path),
           root_id = "#{plugin.plugin_id}:#{relative_path}",
           false <- MapSet.member?(ids, root_id) do
        {row, _ref} = skill_row(plugin.plugin_id, plugin.trust_status, root_id, relative_path)
        {:cont, {:ok, rows ++ [row], MapSet.put(ids, root_id)}}
      else
        _ -> {:halt, invalid(:invalid_declared_skill_root)}
      end
    end)
    |> case do
      {:ok, rows, _} -> {:ok, rows, %{}}
      error -> error
    end
  end

  defp finalize_skill_rows({:ok, rows, refs, _}), do: {:ok, rows, refs}
  defp finalize_skill_rows(error), do: error

  defp skill_row(owner_id, trust, root_id, relative_path) do
    normalized =
      reference!(
        :skill_root_v1,
        %{"root_id" => root_id, "relative_path" => relative_path, "trust_policy" => trust},
        %{},
        "projection_sha256"
      )

    payload = RowSchemas.canonical_projection(normalized)

    {row(
       :skill_roots,
       owner_id,
       :root_id,
       root_id,
       :lexical,
       root_id,
       :skill_root_v1,
       payload,
       RowSchemas.source_authority_projection(normalized)
     ),
     %{
       "owner_id" => owner_id,
       "root_id" => root_id,
       "projection_sha256" => payload["projection_sha256"]
     }}
  end

  defp repository_skill_path(path) when is_binary(path) do
    markers =
      Path.split(path)
      |> Enum.with_index()
      |> Enum.filter(fn {segment, _} -> segment == "plugins" end)

    case markers do
      [{"plugins", index}] ->
        relative = path |> Path.split() |> Enum.drop(index) |> Path.join()

        if Path.type(relative) == :relative and Path.basename(relative) == "skills",
          do: {:ok, relative},
          else: invalid(:invalid_repository_skill_path)

      _ ->
        invalid(:invalid_repository_skill_path)
    end
  end

  defp repository_skill_path(_), do: invalid(:invalid_repository_skill_path)

  defp declared_skill_path(%{root_path: root_path, plugin_id: plugin_id}, path)
       when is_binary(root_path) and is_binary(path) do
    root = Path.expand(root_path)
    expanded = Path.expand(path)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      suffix = if expanded == root, do: [], else: Path.split(Path.relative_to(expanded, root))
      {:ok, Path.join(["plugins", plugin_id | suffix])}
    else
      invalid(:declared_skill_outside_root)
    end
  end

  defp declared_skill_path(_, _), do: invalid(:invalid_declared_skill_path)

  defp skill_app_id(plugin, apps, path) do
    expanded = Path.expand(path)

    case Enum.filter(apps, fn app ->
           app.module in plugin.apps and
             Enum.count(app.skill_paths, &(Path.expand(&1) == expanded)) == 1
         end) do
      [%{app_id: app_id}] -> {:ok, app_id}
      _ -> invalid(:ambiguous_skill_app)
    end
  end

  defp binding_index(bindings) when is_list(bindings) do
    bindings
    |> Enum.reduce_while({:ok, %{}}, fn
      %ActionBinding{} = binding, {:ok, index} ->
        ref = action_ref(binding)
        module = module_name(binding.module)

        case Map.fetch(index, module) do
          :error -> {:cont, {:ok, Map.put(index, module, ref)}}
          {:ok, ^ref} -> {:cont, {:ok, index}}
          _ -> {:halt, invalid(:ambiguous_action_binding)}
        end

      _, _ ->
        {:halt, invalid(:invalid_action_binding)}
    end)
  end

  defp binding_index(_), do: invalid(:invalid_action_bindings)

  defp action_ref(binding) do
    authority = %{
      "kind" => "action",
      "module" => module_name(binding.module),
      "name" => binding.name,
      "normalized_capability" => closed_value(binding.normalized_capability),
      "input_schema_sha256" => binding.input_schema_sha256,
      "output_schema_sha256" => binding.output_schema_sha256
    }

    normalized =
      reference!(
        :action_ref_v1,
        %{
          "module" => module_name(binding.module),
          "name" => binding.name,
          "registry_order" => binding.registry_order
        },
        authority,
        "binding_sha256"
      )

    payload = RowSchemas.canonical_projection(normalized)

    %{
      "module" => payload["module"],
      "name" => payload["name"],
      "binding_sha256" => payload["binding_sha256"]
    }
  end

  defp app_rows(apps, owners, bindings, settings_refs, surface_refs, skill_refs, intent_refs) do
    apps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {app, index}, {:ok, rows} ->
      with {:ok, owner_id} <-
             Map.fetch(owners.by_module, app.module) |> map_fetch_result(:unknown_app_owner),
           {:ok, action_refs} <- app_action_refs(app.actions, bindings),
           {:ok, authority} <-
             app_authority(
               app,
               action_refs,
               Map.get(settings_refs, app.app_id, []),
               Map.get(surface_refs, app.app_id, []),
               Map.get(skill_refs, app.app_id, []),
               Map.get(intent_refs, app.app_id, [])
             ) do
        normalized =
          reference!(
            :app_descriptor_v1,
            %{"module" => module_name(app.module), "app_id" => canonical_string(app.app_id)},
            authority,
            "contract_sha256"
          )

        payload = RowSchemas.canonical_projection(normalized)

        row =
          row(
            :apps,
            owner_id,
            :app_id,
            payload["app_id"],
            :legacy_index,
            index,
            :app_descriptor_v1,
            payload,
            RowSchemas.source_authority_projection(normalized)
          )

        {:cont, {:ok, append(rows, owner_id, row)}}
      else
        _ -> {:halt, invalid(:invalid_app)}
      end
    end)
  end

  defp app_action_refs(actions, bindings) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, refs} ->
      case Map.fetch(bindings, module_name(action)) do
        {:ok, ref} -> {:cont, {:ok, refs ++ [ref]}}
        :error -> {:halt, invalid(:missing_app_action_binding)}
      end
    end)
  end

  defp app_authority(app, action_refs, settings_refs, surface_refs, skill_refs, intent_refs) do
    memory_namespace =
      case app.memory_namespace do
        nil ->
          nil

        value when is_map(value) ->
          %{
            "app_id" => field(value, :app_id),
            "namespace" => field(value, :namespace),
            "writable" => field(value, :writable),
            "description" => field(value, :description)
          }

        _ ->
          throw(:invalid_memory_namespace)
      end

    {:ok,
     %{
       "app_id" => app.app_id,
       "module" => app.module,
       "display_name" => app.display_name,
       "version" => app.version,
       "actions" => action_refs,
       "agents" => app.agents,
       "signals" => %{
         "emits" => field(app.signals, :emits, []),
         "subscribes" => field(app.signals, :subscribes, [])
       },
       "memory_namespace" => memory_namespace,
       "surface_provider" => app.surface_provider,
       "surface_refs" => surface_refs,
       "surface_catalog" =>
         Enum.map(
           app.surface_catalog,
           &%{
             "component" => field(&1, :component),
             "allowed_props" => field(&1, :allowed_props, []),
             "allowed_bindings" => field(&1, :allowed_bindings, [])
           }
         ),
       "skill_root_refs" => skill_refs,
       "settings_fragment_refs" => settings_refs,
       "intent_descriptor_refs" => intent_refs,
       "child_id" => child_id(app.child_id),
       "metadata" => closed_value(app.metadata)
     }}
  catch
    :invalid_memory_namespace -> invalid(:invalid_memory_namespace)
  end

  defp fragment_ref(payload),
    do: %{
      "fragment_id" => payload["fragment_id"],
      "projection_sha256" => payload["projection_sha256"]
    }

  defp row(kind, owner, namespace, identity, order_namespace, order, schema, payload, authority),
    do: %Row{
      schema_version: 1,
      kind: kind,
      owner_id: owner,
      identity: %{namespace: namespace, value: identity},
      order: %{namespace: order_namespace, value: order},
      payload_schema: schema,
      payload: payload,
      source_authority: authority,
      m0_payload_sha256: nil
    }

  defp append(rows, owner, value), do: Map.update(rows, owner, [value], &(&1 ++ [value]))

  defp reference!(schema, payload, authority, digest_field) do
    placeholder = Map.put(payload, digest_field, String.duplicate("0", 64))

    digest =
      RowSchemas.reference_digest_for!(schema, %RowSchemas.Input{
        payload: placeholder,
        source_authority: authority
      })

    RowSchemas.normalize!(schema, %RowSchemas.Input{
      payload: Map.put(payload, digest_field, digest),
      source_authority: authority
    })
  end

  defp canonical_id(value) when is_atom(value) and value not in [nil, true, false],
    do: {:ok, Atom.to_string(value)}

  defp canonical_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp canonical_id(_), do: invalid(:invalid_canonical_id)
  defp canonical_string(value), do: value |> canonical_id() |> elem(1)
  defp module_name(nil), do: nil

  defp module_name(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp field(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp child_id(nil), do: nil
  defp child_id(value) when is_integer(value) or is_binary(value), do: value

  defp child_id(value) when is_atom(value) and value not in [nil, true, false],
    do: module_name(value)

  defp child_id(value) when is_tuple(value),
    do: %{"tuple" => value |> Tuple.to_list() |> Enum.map(&child_id/1)}

  defp child_id(_), do: raise(ArgumentError)
  defp closed_value(nil), do: nil

  defp closed_value(value)
       when is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value),
       do: value

  defp closed_value(value) when is_atom(value), do: module_name(value)
  defp closed_value(value) when is_list(value), do: Enum.map(value, &closed_value/1)
  defp closed_value(%{__struct__: _}), do: raise(ArgumentError)

  defp closed_value(value) when is_map(value),
    do:
      Enum.reduce(value, %{}, fn {key, nested}, acc ->
        Map.put(acc, if(is_atom(key), do: Atom.to_string(key), else: key), closed_value(nested))
      end)

  defp closed_value(_), do: raise(ArgumentError)

  defp map_all(values, mapper) when is_list(values),
    do:
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case mapper.(value) do
          {:ok, mapped} -> {:cont, {:ok, acc ++ [mapped]}}
          error -> {:halt, error}
        end
      end)

  defp map_all(_, _), do: invalid(:invalid_list)
  defp map_fetch_result({:ok, value}, _), do: {:ok, value}
  defp map_fetch_result(:error, reason), do: invalid(reason)
  defp invalid(reason), do: {:error, [diagnostic(reason)]}

  defp diagnostic(reason),
    do: %ValidationDiagnostic{
      schema_version: 1,
      code: :invalid_value,
      path: [],
      owner: nil,
      detail: %{reason: reason}
    }
end
