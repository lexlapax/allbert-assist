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
         :ok <- ensure_no_live_revision(draft),
         :ok <- MetadataStore.verify_source_hashes(draft),
         {:ok, manifest} <- MetadataStore.get_manifest(slug),
         {:ok, validation} <- TrustedValidator.validate(draft, manifest),
         {:ok, integrated_root} <- copy_to_integration_root(draft),
         integrated_draft <- put_root(draft, integrated_root),
         {:ok, modules} <- compile_sources(validation.source_files),
         :ok <- ensure_compiled_modules(validation.modules, modules),
         {:ok, entries} <- overlay_entries(draft, validation, modules),
         :ok <- ActionsOverlay.register_many(entries, existing_names: existing_action_names()),
         {:ok, integrated_draft} <-
           persist_integrated(draft, integrated_draft, manifest, validation),
         {:ok, draft} <- persist_draft_integrated(draft, validation) do
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
        _ = unwind_failed_integration(slug, draft_revision(slug))
        record_validation_failure(slug, reason)
        {:error, reason}
    end
  end

  @doc "Rollback one integrated dynamic artifact after operator confirmation."
  def rollback(slug, revision \\ nil, opts \\ []) when is_binary(slug) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, integration} <- MetadataStore.get_integration(slug, revision),
         :ok <- ensure_confirmation(integration, "rollback_id", context),
         {:ok, removed} <- ActionsOverlay.unregister(slug, integration.revision),
         :ok <- purge_modules(Enum.map(removed, & &1.module)),
         {:ok, integration} <- persist_rolled_back_integration(integration),
         {:ok, draft} <- persist_rolled_back_draft(slug, integration.revision) do
      {:ok,
       %{
         slug: slug,
         revision: integration.revision,
         status: :completed,
         removed_actions: Enum.map(removed, &Map.take(&1, [:name, :module])),
         integration: Draft.summary(integration),
         draft: maybe_summary(draft)
       }}
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
             Map.put(context, :audit?, false)
           ) do
      :ok = ActionsOverlay.clear()
      {:ok, %{status: :completed, live_loader_enabled: false}}
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
         {:ok, modules} <- compile_sources(validation.source_files),
         :ok <- ensure_compiled_modules(validation.modules, modules),
         {:ok, entries} <- overlay_entries(integration, validation, modules),
         :ok <- ActionsOverlay.register_many(entries, existing_names: existing_action_names()) do
      %{slug: integration.slug, revision: integration.revision, status: :completed}
    else
      {:error, reason} ->
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
        ensure_confirmation_record_resumable(expected_id)
    end
  end

  defp ensure_stored_confirmation(%Draft{} = draft, field) do
    case get_in(draft.confirmations, [field]) do
      id when is_binary(id) and id != "" -> ensure_confirmation_record_approved(id)
      _other -> {:error, {:missing_confirmation, field}}
    end
  end

  defp ensure_confirmation_record_approved(id) do
    case Confirmations.read(id) do
      {:ok, %{"status" => "approved"}} -> :ok
      {:ok, %{"status" => status}} -> {:error, {:confirmation_not_approved, id, status}}
      {:error, reason} -> {:error, {:confirmation_not_found, id, reason}}
    end
  end

  defp ensure_confirmation_record_resumable(id) do
    case Confirmations.read(id) do
      {:ok, %{"status" => status}} when status in ["pending", "approved"] ->
        :ok

      {:ok, %{"status" => status}} ->
        {:error, {:confirmation_not_resumable, id, status}}

      {:error, reason} ->
        {:error, {:confirmation_not_found, id, reason}}
    end
  end

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

  defp unwind_failed_integration(slug, revision) do
    _ = ActionsOverlay.unregister(slug, revision)

    case revision do
      nil ->
        :ok

      revision ->
        case MetadataStore.get_integration(slug, revision) do
          {:ok, %Draft{tier: "integrated"}} ->
            :ok

          _other ->
            root = MetadataStore.integration_root_for(slug, revision)
            remove_integration_root(root)
        end
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
