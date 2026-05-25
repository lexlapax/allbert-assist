defmodule AllbertAssist.DynamicPlugins.Loader do
  @moduledoc """
  Trusted v0.37 live loader for integrated dynamic action artifacts.

  The loader accepts only gate-passed, operator-confirmed, read-only action
  drafts. It copies reviewed source into the integrated root, validates AST
  allowlists, compiles the reviewed source, registers action modules in the
  runtime overlay, and can remove that authority through rollback or emergency
  disable.
  """

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Settings

  @doc "Integrate one gate-passed draft after operator confirmation."
  def integrate(slug, opts \\ []) when is_binary(slug) do
    context = Keyword.get(opts, :context, %{})

    with :ok <- live_loader_enabled(),
         {:ok, draft} <- MetadataStore.get_draft(slug),
         :ok <- ensure_gate_passed(draft),
         :ok <- ensure_confirmation(draft, "integration_id", context),
         :ok <- audit_event(:integration_attempted, draft, context_metadata(context)),
         :ok <- ensure_no_live_revision(draft),
         :ok <- MetadataStore.verify_source_hashes(draft),
         {:ok, manifest} <- MetadataStore.get_manifest(slug),
         {:ok, validation} <- TrustedValidator.validate(draft, manifest),
         :ok <- audit_event(:trusted_validation_passed, draft, validation_metadata(validation)),
         {:ok, integrated_root} <- copy_to_integration_root(draft),
         integrated_draft <- put_root(draft, integrated_root),
         :ok <- purge_generated_modules(validation.modules),
         {:ok, modules} <- compile_sources(validation.source_files),
         :ok <- audit_event(:compiled, draft, %{modules: validation.modules}),
         :ok <- ensure_compiled_modules(validation.modules, modules),
         {:ok, entries} <- overlay_entries(draft, validation, modules),
         :ok <- ActionsOverlay.register_many(entries, existing_names: existing_action_names()),
         :ok <- audit_event(:registered, draft, %{actions: Enum.map(entries, & &1.name)}),
         {:ok, integrated_draft} <-
           persist_integrated(draft, integrated_draft, manifest, validation),
         {:ok, draft} <- persist_draft_integrated(draft, validation),
         :ok <- audit_event(:integrated, draft, validation_metadata(validation)) do
      {:ok,
       %{
         slug: slug,
         revision: draft.revision,
         status: :completed,
         integration: Draft.summary(integrated_draft),
         draft: Draft.summary(draft),
         modules: validation.modules,
         actions: Enum.map(entries, &Map.take(&1, [:name, :module, :exposure]))
       }}
    else
      {:error, reason} ->
        _ = unwind_failed_integration(slug, draft_revision(slug), reason)
        record_validation_failure(slug, reason)
        _ = audit_denied(:integration_denied, slug, reason, context)
        {:error, reason}
    end
  end

  @doc "Rollback one integrated dynamic artifact after operator confirmation."
  def rollback(slug, revision \\ nil, opts \\ []) when is_binary(slug) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, integration} <- MetadataStore.get_integration(slug, revision),
         :ok <- ensure_confirmation(integration, "rollback_id", context),
         :ok <- audit_event(:rollback_requested, integration, context_metadata(context)),
         {:ok, removed} <- ActionsOverlay.unregister(slug, integration.revision),
         :ok <- purge_modules(Enum.map(removed, & &1.module)),
         {:ok, integration} <- persist_rolled_back_integration(integration),
         {:ok, draft} <- persist_rolled_back_draft(slug, integration.revision),
         :ok <-
           audit_event(:rolled_back, integration, %{
             removed_actions: Enum.map(removed, & &1.name)
           }) do
      {:ok,
       %{
         slug: slug,
         revision: integration.revision,
         status: :completed,
         removed_actions: Enum.map(removed, &Map.take(&1, [:name, :module])),
         integration: Draft.summary(integration),
         draft: maybe_summary(draft)
       }}
    else
      {:error, reason} ->
        _ = audit_denied(:rollback_denied, slug, reason, context)
        {:error, reason}
    end
  end

  @doc "Clear live dynamic authority and turn off the live-loader setting."
  @spec disable(keyword()) :: {:ok, map()} | {:error, term()}
  def disable(opts \\ []) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, _setting} <-
           Settings.put(
             "dynamic_codegen.live_loader_enabled",
             false,
             context
           ) do
      :ok = ActionsOverlay.clear()

      with {:ok, _path} <-
             Audit.append(
               :live_loader_disabled,
               Map.merge(%{cleared_overlay?: true}, context_metadata(context))
             ) do
        {:ok, %{status: :completed, live_loader_enabled: false}}
      end
    end
  end

  @doc "Reconcile integrated metadata into the overlay on boot or explicit request."
  @spec reconcile(keyword()) :: {:ok, map()}
  def reconcile(opts \\ []) do
    if live_loader_enabled?() do
      integrations =
        MetadataStore.list_integrations()
        |> Enum.filter(&(&1.tier == "integrated"))
        |> Enum.map(&reconcile_integration(&1, opts))

      {:ok, %{status: :completed, integrations: integrations}}
    else
      :ok = ActionsOverlay.clear()
      {:ok, %{status: :disabled, integrations: []}}
    end
  end

  defp reconcile_integration(%Draft{} = integration, _opts) do
    with :ok <- MetadataStore.verify_source_hashes(integration),
         :ok <- ensure_stored_confirmation(integration, "integration_id"),
         {:ok, manifest} <-
           MetadataStore.get_integration_manifest(integration.slug, integration.revision),
         {:ok, validation} <- TrustedValidator.validate(integration, manifest),
         :ok <- purge_generated_modules(validation.modules),
         {:ok, modules} <- compile_sources(validation.source_files),
         :ok <- ensure_compiled_modules(validation.modules, modules),
         {:ok, entries} <- overlay_entries(integration, validation, modules),
         :ok <- ActionsOverlay.register_many(entries, existing_names: existing_action_names()),
         :ok <-
           audit_event(:reconcile_completed, integration, %{
             actions: Enum.map(entries, & &1.name)
           }) do
      %{slug: integration.slug, revision: integration.revision, status: :completed}
    else
      {:error, reason} ->
        _ = ActionsOverlay.unregister(integration.slug, integration.revision)
        _ = purge_generated_modules(manifest_module_names(integration.slug))
        _ = audit_event(:reconcile_denied, integration, %{reason: inspect(reason)})

        %{
          slug: integration.slug,
          revision: integration.revision,
          status: :denied,
          error: inspect(reason)
        }
    end
  end

  defp live_loader_enabled do
    if live_loader_enabled?(), do: :ok, else: {:error, :dynamic_live_loader_disabled}
  end

  defp live_loader_enabled? do
    case Settings.get("dynamic_codegen.live_loader_enabled") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp ensure_gate_passed(%Draft{tier: "gate_passed", gate: %{"status" => "passed"}}), do: :ok
  defp ensure_gate_passed(%Draft{tier: "integrated"}), do: {:error, :draft_already_integrated}
  defp ensure_gate_passed(%Draft{} = draft), do: {:error, {:draft_not_gate_passed, draft.tier}}

  defp ensure_confirmation(%Draft{} = draft, field, context) do
    expected_id = get_in(draft.confirmations, [field])
    approved_id = approved_confirmation_id(context)

    cond do
      is_nil(expected_id) or expected_id == "" ->
        {:error, {:missing_confirmation, field}}

      approved_id != expected_id ->
        {:error, {:confirmation_mismatch, %{expected: expected_id, actual: approved_id}}}

      true ->
        ensure_confirmation_record_resumable(expected_id, expected_confirmation_action(field))
    end
  end

  defp ensure_stored_confirmation(%Draft{} = draft, field) do
    case get_in(draft.confirmations, [field]) do
      id when is_binary(id) and id != "" ->
        ensure_confirmation_record_approved(id, expected_confirmation_action(field))

      _other ->
        {:error, {:missing_confirmation, field}}
    end
  end

  defp ensure_confirmation_record_approved(id, expected_action) do
    case Confirmations.read(id) do
      {:ok, %{"status" => "approved"} = record} ->
        ensure_dynamic_confirmation_record(record, expected_action)

      {:ok, %{"status" => status}} ->
        {:error, {:confirmation_not_approved, id, status}}

      {:error, reason} ->
        {:error, {:confirmation_not_found, id, reason}}
    end
  end

  defp ensure_confirmation_record_resumable(id, expected_action) do
    case Confirmations.read(id) do
      {:ok, %{"status" => "approved"} = record} ->
        with :ok <- ensure_dynamic_confirmation_record(record, expected_action) do
          ensure_dynamic_confirmation_resuming(record)
        end

      {:ok, %{"status" => status}} ->
        {:error, {:confirmation_not_approved_for_dynamic_resume, id, status}}

      {:error, reason} ->
        {:error, {:confirmation_not_found, id, reason}}
    end
  end

  defp ensure_dynamic_confirmation_record(record, expected_action) do
    cond do
      get_in(record, ["target_action", "name"]) != expected_action ->
        {:error,
         {:dynamic_confirmation_target_mismatch,
          %{expected: expected_action, actual: get_in(record, ["target_action", "name"])}}}

      Map.get(record, "target_permission") != "dynamic_integration" ->
        {:error,
         {:dynamic_confirmation_permission_mismatch, Map.get(record, "target_permission")}}

      Map.get(record, "target_execution_mode") != "dynamic_loader" ->
        {:error,
         {:dynamic_confirmation_execution_mode_mismatch, Map.get(record, "target_execution_mode")}}

      true ->
        ensure_dynamic_confirmation_resolution(record)
    end
  end

  defp ensure_dynamic_confirmation_resolution(record) do
    resolution = Map.get(record, "operator_resolution", %{}) || %{}
    resolver_surface = normalize_dynamic_surface(Map.get(resolution, "resolver_surface"))

    cond do
      resolution == %{} ->
        {:error, {:dynamic_confirmation_resolution_missing, Map.get(record, "id")}}

      resolver_surface not in allowed_dynamic_surfaces() ->
        {:error, {:dynamic_integration_approval_surface_denied, resolver_surface}}

      Map.get(resolution, "same_channel?") != true ->
        {:error, :dynamic_integration_cross_channel_approval_denied}

      true ->
        :ok
    end
  end

  defp ensure_dynamic_confirmation_resuming(record) do
    resolution = Map.get(record, "operator_resolution", %{}) || %{}

    case Map.get(resolution, "target_status") do
      "resuming" -> :ok
      status -> {:error, {:dynamic_confirmation_not_resuming, Map.get(record, "id"), status}}
    end
  end

  defp expected_confirmation_action("integration_id"), do: "integrate_dynamic_draft"
  defp expected_confirmation_action("rollback_id"), do: "rollback_dynamic_integration"
  defp expected_confirmation_action(field), do: field

  defp approved_confirmation_id(context) do
    cond do
      get_in(context, [:confirmation, :approved?]) == true ->
        get_in(context, [:confirmation, :id])

      get_in(context, ["confirmation", "approved?"]) == true ->
        get_in(context, ["confirmation", "id"])

      true ->
        nil
    end
  end

  defp allowed_dynamic_surfaces do
    case Settings.get("dynamic_codegen.integration_approval_surfaces") do
      {:ok, surfaces} when is_list(surfaces) ->
        Enum.map(surfaces, &normalize_dynamic_surface/1)

      _other ->
        ["cli", "liveview"]
    end
  end

  defp normalize_dynamic_surface("live_view"), do: "liveview"
  defp normalize_dynamic_surface("liveview"), do: "liveview"
  defp normalize_dynamic_surface(:liveview), do: "liveview"
  defp normalize_dynamic_surface(:live_view), do: "liveview"
  defp normalize_dynamic_surface(:cli), do: "cli"
  defp normalize_dynamic_surface("cli"), do: "cli"
  defp normalize_dynamic_surface(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_dynamic_surface(value) when is_binary(value), do: value
  defp normalize_dynamic_surface(value), do: inspect(value)

  defp ensure_no_live_revision(%Draft{} = draft) do
    case MetadataStore.get_integration(draft.slug, nil) do
      {:ok, %Draft{tier: "integrated", revision: revision}} ->
        {:error, {:dynamic_integration_already_live, draft.slug, revision}}

      {:ok, _rolled_back} ->
        :ok

      {:error, :integration_not_found} ->
        :ok

      {:error, {:metadata_not_found, _path}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_to_integration_root(%Draft{} = draft) do
    root = MetadataStore.integration_root_for(draft.slug, draft.revision)

    if File.exists?(root) do
      {:error, {:integration_root_exists, root}}
    else
      copy_draft_root(draft.root, root)
    end
  end

  defp copy_draft_root(source_root, target_root) do
    with :ok <- File.mkdir_p(Path.dirname(target_root)) do
      case File.cp_r(source_root, target_root) do
        {:ok, _files} -> {:ok, target_root}
        {:error, reason, file} -> {:error, {:integration_copy_failed, file, reason}}
      end
    end
  end

  defp put_root(%Draft{} = draft, root), do: %{draft | root: root}

  defp compile_sources(source_files) do
    Enum.reduce_while(source_files, {:ok, []}, fn source_file, {:ok, acc} ->
      {result, diagnostics} =
        Code.with_diagnostics(fn ->
          try do
            {:ok, Code.compile_string(source_file.source, source_file.path)}
          rescue
            exception ->
              {:error, {exception.__struct__, Exception.message(exception)}}
          end
        end)

      cond do
        diagnostics != [] ->
          {:halt, {:error, {:dynamic_compile_diagnostics, diagnostics}}}

        match?({:ok, _modules}, result) ->
          {:ok, modules} = result
          {:cont, {:ok, acc ++ modules}}

        true ->
          {:halt, result}
      end
    end)
  end

  defp ensure_compiled_modules(expected, compiled) do
    compiled_names =
      compiled
      |> Enum.map(fn {module, _bytecode} -> inspect(module) end)
      |> Enum.sort()

    if compiled_names == Enum.sort(expected) do
      :ok
    else
      purge_modules(Enum.map(compiled, fn {module, _bytecode} -> module end))
      {:error, {:compiled_module_mismatch, %{expected: expected, compiled: compiled_names}}}
    end
  end

  defp overlay_entries(%Draft{} = draft, validation, compiled) do
    compiled_modules =
      MapSet.new(Enum.map(compiled, fn {module, _bytecode} -> inspect(module) end))

    entries =
      Enum.map(validation.actions, fn action ->
        module = string_to_existing_module(action.module, compiled_modules)

        %{
          name: action.name,
          module: module,
          slug: draft.slug,
          revision: draft.revision,
          exposure: String.to_existing_atom(action.exposure)
        }
      end)

    if Enum.any?(entries, &is_nil(&1.module)) do
      {:error, {:dynamic_action_module_not_compiled, validation.actions}}
    else
      {:ok, entries}
    end
  end

  defp string_to_existing_module(module_name, compiled_modules) do
    if MapSet.member?(compiled_modules, module_name) do
      module_name
      |> String.split(".")
      |> Module.safe_concat()
    end
  rescue
    _exception -> nil
  end

  defp existing_action_names do
    ActionsRegistry.names()
    |> Enum.reject(fn name ->
      module =
        case ActionsRegistry.resolve(name) do
          {:ok, module} -> module
          {:error, _reason} -> nil
        end

      module in ActionsOverlay.modules()
    end)
  end

  defp persist_integrated(original_draft, integrated_draft, manifest, validation) do
    with {:ok, integrated} <- Draft.put_tier(integrated_draft, "integrated"),
         integrated <- put_validation(integrated, "passed", validation),
         integrated <-
           put_confirmation(
             integrated,
             "integration_id",
             get_in(original_draft.confirmations, ["integration_id"])
           ),
         {:ok, integrated} <- MetadataStore.put_integration(integrated),
         :ok <-
           MetadataStore.put_integration_manifest(integrated.slug, integrated.revision, manifest) do
      {:ok, integrated}
    end
  end

  defp persist_draft_integrated(%Draft{} = draft, validation) do
    with {:ok, draft} <- Draft.put_tier(draft, "integrated"),
         draft <- put_validation(draft, "passed", validation) do
      MetadataStore.put_draft(draft)
    end
  end

  defp persist_rolled_back_integration(%Draft{} = integration) do
    with {:ok, integration} <- Draft.put_tier(integration, "rolled_back") do
      MetadataStore.put_integration(integration)
    end
  end

  defp persist_rolled_back_draft(slug, revision) do
    case MetadataStore.get_draft(slug) do
      {:ok, %Draft{revision: ^revision} = draft} ->
        with {:ok, draft} <- Draft.put_tier(draft, "rolled_back") do
          MetadataStore.put_draft(draft)
        end

      {:ok, draft} ->
        {:ok, draft}

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp record_validation_failure(slug, reason) do
    with {:ok, draft} <- MetadataStore.get_draft(slug) do
      draft
      |> put_validation("failed", %{diagnostics: [%{reason: inspect(reason)}]})
      |> MetadataStore.put_draft()
    else
      _other -> :ok
    end
  end

  defp unwind_failed_integration(slug, revision, reason) do
    {:ok, removed} = ActionsOverlay.unregister(slug, revision)
    _ = purge_modules(Enum.map(removed, & &1.module))

    unless preserve_loaded_modules?(reason) do
      _ = purge_generated_modules(manifest_module_names(slug))
    end

    cond do
      is_nil(revision) ->
        :ok

      match?({:integration_root_exists, _root}, reason) ->
        :ok

      true ->
        slug
        |> MetadataStore.integration_root_for(revision)
        |> remove_integration_root()
    end
  end

  defp draft_revision(slug) do
    case MetadataStore.get_draft(slug) do
      {:ok, draft} -> draft.revision
      {:error, _reason} -> nil
    end
  end

  defp remove_integration_root(root) do
    integrated_root = Path.expand(MetadataStore.integrated_root())
    root = Path.expand(root)

    if String.starts_with?(root, integrated_root <> "/") do
      File.rm_rf(root)
      :ok
    else
      {:error, {:unsafe_integration_root_cleanup, root}}
    end
  end

  defp purge_modules(modules) do
    Enum.each(modules, fn module ->
      :code.purge(module)
      :code.delete(module)
    end)

    :ok
  end

  defp purge_generated_modules(module_names) when is_list(module_names) do
    module_names
    |> Enum.map(&generated_module_from_string/1)
    |> Enum.reject(&is_nil/1)
    |> purge_modules()
  end

  defp generated_module_from_string(
         "AllbertAssist.DynamicPlugins.Generated." <> _rest = module_name
       ) do
    module_name
    |> String.split(".")
    |> Module.safe_concat()
  rescue
    _exception -> nil
  end

  defp generated_module_from_string(_module_name), do: nil

  defp preserve_loaded_modules?({:dynamic_integration_already_live, _slug, _revision}), do: true
  defp preserve_loaded_modules?({:integration_root_exists, _root}), do: true
  defp preserve_loaded_modules?(_reason), do: false

  defp manifest_module_names(slug) do
    case MetadataStore.get_manifest(slug) do
      {:ok, %{"modules" => modules}} when is_list(modules) -> modules
      {:ok, %{modules: modules}} when is_list(modules) -> modules
      _other -> []
    end
  end

  defp audit_event(event, %Draft{} = draft, metadata) when is_map(metadata) do
    with {:ok, _path} <-
           Audit.append(event, Map.merge(draft_metadata(draft), metadata)) do
      :ok
    end
  end

  defp audit_denied(event, slug, reason, context) do
    Audit.append(
      event,
      Map.merge(context_metadata(context), %{
        slug: slug,
        reason: inspect(reason)
      })
    )
  end

  defp draft_metadata(%Draft{} = draft) do
    %{
      slug: draft.slug,
      revision: draft.revision,
      tier: draft.tier,
      target_shapes: draft.target_shapes,
      gate_status: Map.get(draft.gate, "status"),
      integration_confirmation_id: get_in(draft.confirmations, ["integration_id"]),
      rollback_confirmation_id: get_in(draft.confirmations, ["rollback_id"])
    }
  end

  defp validation_metadata(validation) do
    %{
      modules: Map.get(validation, :modules, []),
      actions: validation |> Map.get(:actions, []) |> Enum.map(&Map.take(&1, [:name, :module]))
    }
  end

  defp context_metadata(context) when is_map(context) do
    %{
      operator_id: Map.get(context, :operator_id) || Map.get(context, "operator_id"),
      actor: Map.get(context, :actor) || Map.get(context, "actor"),
      channel: Map.get(context, :channel) || Map.get(context, "channel"),
      surface: Map.get(context, :surface) || Map.get(context, "surface")
    }
  end

  defp context_metadata(_context), do: %{}

  defp put_validation(%Draft{} = draft, status, validation) do
    modules = Map.get(validation, :modules, [])
    actions = Map.get(validation, :actions, [])
    diagnostics = Map.get(validation, :diagnostics, [])

    %{
      draft
      | static_validation: %{
          "status" => status,
          "modules" => modules,
          "actions" => Enum.map(actions, &stringify_keys/1)
        },
        diagnostics: diagnostics ++ draft.diagnostics
    }
  end

  defp put_confirmation(%Draft{} = draft, field, id) do
    %{draft | confirmations: Map.put(draft.confirmations, field, id)}
  end

  defp maybe_summary(nil), do: nil
  defp maybe_summary(%Draft{} = draft), do: Draft.summary(draft)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
