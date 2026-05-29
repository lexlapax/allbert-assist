defmodule AllbertAssist.DynamicPlugins.Codegen.Producer do
  @moduledoc """
  Producer-neutral v0.37 draft request entrypoint.

  The v0.37 implementation writes source-bearing action drafts
  after explicit operator/objective requests pass settings, provider-profile,
  and budget checks. The generated source remains untrusted draft evidence until
  sandbox gate, trusted validation, and operator-confirmed integration pass.
  """

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.Codegen.Budget
  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Codegen.Roles
  alias AllbertAssist.DynamicPlugins.Codegen.Targets.Action, as: ActionTarget
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.Objectives
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @metadata_file "metadata.yaml"
  @manifest_file "manifest.yaml"

  @doc "Request a source-bearing action draft for a normalized capability gap."
  @spec request_draft(map(), map()) :: {:ok, map()} | {:error, term()}
  def request_draft(attrs, context \\ %{}) when is_map(attrs) and is_map(context) do
    with :ok <- ensure_enabled(),
         {:ok, gap} <- CapabilityGap.new(attrs, context),
         :ok <- CapabilityGap.ensure_explicit(gap),
         {:ok, profile} <- dynamic_provider_profile(context),
         :ok <- ensure_provider_ready(profile),
         {:ok, budget} <- budget_for(attrs, gap),
         {:ok, role_packets, generated, budget} <- Roles.run(gap, profile, budget, context),
         {:ok, draft, manifest} <- write_draft(gap, profile, budget, generated, role_packets),
         :ok <- audit_draft_requested(gap, draft, profile, budget, context),
         :ok <- record_objective_event(gap, draft, profile, budget) do
      {:ok,
       %{
         draft: Draft.summary(draft),
         gap: CapabilityGap.summary(gap),
         provider_profile: provider_summary(profile),
         budget: budget,
         manifest: manifest_summary(manifest),
         diagnostics: draft.diagnostics
       }}
    end
  end

  @doc "Repair a source-bearing draft from bounded validation or sandbox evidence."
  @spec repair_draft(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def repair_draft(slug, evidence, context \\ %{})
      when is_binary(slug) and is_map(evidence) and is_map(context) do
    with :ok <- ensure_enabled(),
         {:ok, draft} <- MetadataStore.get_draft(slug),
         :ok <- ensure_repairable_draft(draft),
         {:ok, manifest} <- MetadataStore.get_manifest(slug),
         {:ok, generated} <- current_generated(draft, manifest),
         {:ok, gap} <- repair_gap(draft, manifest, context),
         {:ok, profile} <- provider_profile(draft.provider_profile, context),
         :ok <- ensure_provider_ready(profile),
         {:ok, role_packets, repaired, budget} <-
           Roles.repair_from_evidence(gap, profile, draft.budget, context, generated, evidence),
         :ok <- archive_revision(draft, manifest),
         {:ok, repaired_draft, repaired_manifest} <-
           write_draft(gap, profile, budget, repaired, role_packets,
             previous_draft: draft,
             evidence: evidence
           ),
         :ok <- audit_draft_repaired(draft, repaired_draft, profile, budget, evidence, context),
         :ok <- record_repair_objective_event(gap, repaired_draft, profile, budget, evidence) do
      {:ok,
       %{
         draft: Draft.summary(repaired_draft),
         gap: CapabilityGap.summary(gap),
         provider_profile: provider_summary(profile),
         budget: budget,
         manifest: manifest_summary(repaired_manifest),
         diagnostics: repaired_draft.diagnostics
       }}
    end
  end

  defp ensure_enabled do
    case Settings.get("dynamic_codegen.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :dynamic_codegen_disabled}
    end
  end

  defp dynamic_provider_profile(context) do
    case Settings.get("dynamic_codegen.provider_profile") do
      {:ok, name} when is_binary(name) and name != "" ->
        provider_profile(name, context)

      _other ->
        {:error, :missing_dynamic_codegen_provider_profile}
    end
  end

  defp provider_profile(name, context) when is_binary(name) and name != "" do
    case Settings.resolve_model_profile(name, context) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:error, {:dynamic_codegen_provider_profile_not_found, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_profile(_name, _context), do: {:error, :missing_dynamic_codegen_provider_profile}

  defp ensure_provider_ready(%{provider: provider}) when is_binary(provider) do
    with {:ok, providers} <- Settings.list_provider_profiles() do
      case Enum.find(providers, &(&1.name == provider)) do
        %{enabled: false} ->
          {:error, {:dynamic_codegen_provider_disabled, provider}}

        %{enabled: true, api_key_ref: api_key_ref, credential_status: credential_status} = attrs ->
          ensure_credentials(provider, Map.get(attrs, :type), api_key_ref, credential_status)

        nil ->
          {:error, {:dynamic_codegen_unknown_provider, provider}}
      end
    end
  end

  defp ensure_provider_ready(profile), do: {:error, {:dynamic_codegen_invalid_profile, profile}}

  defp ensure_credentials(_provider, _provider_type, nil, _credential_status), do: :ok
  defp ensure_credentials(_provider, _provider_type, _api_key_ref, :configured), do: :ok

  defp ensure_credentials(provider, provider_type, _api_key_ref, status) do
    if env_credential_available?(provider, provider_type) do
      :ok
    else
      {:error,
       {:dynamic_codegen_provider_credentials_missing, %{provider: provider, status: status}}}
    end
  end

  defp budget_for(attrs, %CapabilityGap{} = gap) do
    attrs
    |> Map.take([
      :provider_calls_requested,
      "provider_calls_requested",
      :provider_usage_units_requested,
      "provider_usage_units_requested"
    ])
    |> Map.merge(gap.budget)
    |> Budget.check()
  end

  defp write_draft(%CapabilityGap{} = gap, profile, budget, generated, role_packets, opts \\ []) do
    module = ActionTarget.module_name(gap.slug)
    test_module = ActionTarget.test_module_name(gap.slug)
    action_name = ActionTarget.action_name(gap.slug, Map.get(generated, "action_name"))

    replacements = %{
      "MODULE" => module,
      "TEST_MODULE" => test_module,
      "ACTION_NAME" => action_name,
      "SLUG" => gap.slug
    }

    source = generated |> Map.fetch!("source") |> ActionTarget.stamp_source(replacements)

    test_source =
      generated |> Map.fetch!("test_source") |> ActionTarget.stamp_source(replacements)

    root = MetadataStore.draft_root(gap.slug)
    source_rel = ActionTarget.source_path()
    test_rel = ActionTarget.test_path()
    source_abs = Path.join(root, source_rel)
    test_abs = Path.join(root, test_rel)

    source_compiled = ActionTarget.compiled_source_path(gap.slug)
    test_compiled = ActionTarget.compiled_test_path(gap.slug)

    previous_draft = Keyword.get(opts, :previous_draft)

    with {:ok, permission} <- source_permission(source),
         target <-
           %{
             module: module,
             action_name: action_name,
             permission: permission,
             source_rel: source_rel,
             source_compiled: source_compiled,
             test_rel: test_rel,
             test_compiled: test_compiled
           },
         :ok <- write_file(source_abs, source),
         :ok <- write_file(test_abs, test_source),
         {:ok, source_hash} <- MetadataStore.hash_file(source_abs),
         {:ok, test_hash} <- MetadataStore.hash_file(test_abs),
         manifest <- manifest(gap, target, generated, role_packets),
         {:ok, draft} <-
           DynamicPlugins.put_draft(
             %{
               slug: gap.slug,
               producer: "codegen_llm",
               provider_profile: profile.name,
               target_shapes: gap.target_shapes,
               source_hashes: %{source_rel => source_hash, test_rel => test_hash},
               compiled_paths: [source_compiled, test_compiled],
               scan_paths: [source_rel, test_rel],
               budget: budget,
               diagnostics:
                 diagnostics(gap, profile, generated, role_packets,
                   previous_draft: previous_draft,
                   evidence: Keyword.get(opts, :evidence)
                 ),
               repair_history: repair_history(generated, role_packets, previous_draft),
               static_validation: %{"status" => "not_run"},
               gate: gate_for(previous_draft)
             },
             put_draft_opts(previous_draft)
           ),
         :ok <- MetadataStore.put_manifest(gap.slug, manifest) do
      {:ok, draft, manifest}
    end
  end

  defp record_objective_event(%CapabilityGap{objective_id: nil}, _draft, _profile, _budget),
    do: :ok

  defp record_objective_event(%CapabilityGap{} = gap, %Draft{} = draft, profile, budget) do
    case Objectives.create_event(%{
           objective_id: gap.objective_id,
           step_id: gap.step_id,
           kind: "observed",
           summary: "Dynamic codegen draft requested for #{draft.slug}.",
           payload: objective_event_payload(gap, draft, profile, budget)
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, {:dynamic_codegen_objective_event_failed, reason}}
    end
  end

  defp record_repair_objective_event(
         %CapabilityGap{objective_id: nil},
         _draft,
         _profile,
         _budget,
         _evidence
       ),
       do: :ok

  defp record_repair_objective_event(
         %CapabilityGap{} = gap,
         %Draft{} = draft,
         profile,
         budget,
         evidence
       ) do
    case Objectives.create_event(%{
           objective_id: gap.objective_id,
           step_id: gap.step_id,
           kind: "observed",
           summary: "Dynamic codegen draft repaired for #{draft.slug}.",
           payload: objective_repair_event_payload(gap, draft, profile, budget, evidence)
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, {:dynamic_codegen_objective_event_failed, reason}}
    end
  end

  defp audit_draft_requested(%CapabilityGap{} = gap, %Draft{} = draft, profile, budget, context) do
    with {:ok, _path} <-
           Audit.append(:draft_requested, %{
             slug: draft.slug,
             revision: draft.revision,
             producer: draft.producer,
             tier: draft.tier,
             target_shapes: draft.target_shapes,
             gap_id: gap.id,
             source: gap.source,
             objective_id: gap.objective_id,
             step_id: gap.step_id,
             provider_profile: profile.name,
             budget: budget,
             operator_id: context_value(context, :operator_id) || context_value(context, :actor),
             channel: context_value(context, :channel),
             surface: context_value(context, :surface)
           }) do
      :ok
    end
  end

  defp audit_draft_repaired(
         %Draft{} = previous,
         %Draft{} = draft,
         profile,
         budget,
         evidence,
         context
       ) do
    with {:ok, _path} <-
           Audit.append(:draft_repaired, %{
             slug: draft.slug,
             revision: draft.revision,
             previous_revision: previous.revision,
             producer: draft.producer,
             tier: draft.tier,
             provider_profile: profile.name,
             budget: budget,
             evidence: bounded_evidence(evidence),
             operator_id: context_value(context, :operator_id) || context_value(context, :actor),
             channel: context_value(context, :channel),
             surface: context_value(context, :surface)
           }) do
      :ok
    end
  end

  defp diagnostics(%CapabilityGap{} = gap, profile, generated, role_packets, opts) do
    previous_draft = Keyword.get(opts, :previous_draft)
    evidence = Keyword.get(opts, :evidence)

    [
      %{
        "source" => "dynamic_codegen",
        "status" => if(previous_draft, do: "source_repaired", else: "source_generated"),
        "message" =>
          if previous_draft do
            "Action draft source repaired from bounded evidence; live authority remains unavailable until sandbox gate and explicit integration."
          else
            "Action draft source generated; live authority remains unavailable until sandbox gate and explicit integration."
          end,
        "gap_id" => gap.id,
        "provider_profile" => profile.name,
        "authority" => "none",
        "notes" => normalize_list(Map.get(generated, "notes")),
        "roles" => role_summary(role_packets),
        "previous_revision" => previous_draft && previous_draft.revision,
        "evidence" => bounded_evidence(evidence)
      }
    ]
    |> Kernel.++(if(previous_draft, do: previous_draft.diagnostics, else: []))
    |> Redactor.redact()
  end

  defp objective_event_payload(%CapabilityGap{} = gap, %Draft{} = draft, profile, budget) do
    %{
      "stage" => "dynamic_codegen_draft_requested",
      "gap_id" => gap.id,
      "draft_slug" => draft.slug,
      "draft_revision" => draft.revision,
      "provider_profile" => profile.name,
      "target_shapes" => gap.target_shapes,
      "budget" => %{
        "provider_calls_budget" => budget["provider_calls_budget"],
        "provider_calls_used" => budget["provider_calls_used"],
        "provider_usage_units_budget" => budget["provider_usage_units_budget"],
        "provider_usage_units_used" => budget["provider_usage_units_used"]
      }
    }
  end

  defp objective_repair_event_payload(
         %CapabilityGap{} = gap,
         %Draft{} = draft,
         profile,
         budget,
         evidence
       ) do
    objective_event_payload(gap, draft, profile, budget)
    |> Map.put("stage", "dynamic_codegen_draft_repaired")
    |> Map.put("evidence", bounded_evidence(evidence))
  end

  defp provider_summary(profile) do
    %{
      "name" => profile.name,
      "provider" => profile.provider,
      "provider_type" => profile.provider_type,
      "model" => profile.model,
      "max_tokens" => profile.max_tokens,
      "timeout_ms" => profile.timeout_ms,
      "credential_status" => profile.credential_status
    }
  end

  defp context_value(context, key), do: Map.get(context, key) || Map.get(context, to_string(key))

  defp env_credential_available?(provider, provider_type) do
    env_keys =
      [provider, provider_type]
      |> Enum.flat_map(&credential_env_keys/1)
      |> Enum.uniq()

    Enum.any?(env_keys, fn key ->
      case System.get_env(key) do
        value when is_binary(value) -> String.trim(value) != ""
        _other -> false
      end
    end)
  end

  defp credential_env_keys("openai"), do: ["OPENAI_API_KEY"]
  defp credential_env_keys("openai_compatible"), do: ["OPENAI_API_KEY"]
  defp credential_env_keys("anthropic"), do: ["ANTHROPIC_API_KEY"]
  defp credential_env_keys("openrouter"), do: ["OPENROUTER_API_KEY"]
  defp credential_env_keys("google"), do: ["GOOGLE_API_KEY"]

  defp credential_env_keys(provider) when is_binary(provider) do
    key = provider |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_")
    [key <> "_API_KEY"]
  end

  defp credential_env_keys(_provider), do: []

  defp write_file(path, contents) when is_binary(contents) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, contents)
    end
  end

  defp manifest(gap, target, generated, role_packets) do
    %{
      "target_shapes" => ["action"],
      "modules" => [target.module],
      "actions" => [
        %{
          "name" => target.action_name,
          "module" => target.module,
          "permission" => target.permission,
          "exposure" => "internal"
        }
      ],
      "files" => [
        %{"source_path" => target.source_rel, "compiled_path" => target.source_compiled}
      ],
      "tests" => [
        %{"source_path" => target.test_rel, "compiled_path" => target.test_compiled}
      ],
      "focused_test_paths" => [target.test_compiled],
      "generation" => %{
        "gap_id" => gap.id,
        "description" => Map.get(generated, "description"),
        "notes" => normalize_list(Map.get(generated, "notes")),
        "roles" => role_summary(role_packets)
      }
    }
  end

  defp source_permission(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, permission} <- parsed_action_permission(ast) do
      {:ok, Atom.to_string(permission)}
    else
      {:error, reason} -> {:error, {:dynamic_codegen_source_permission_unavailable, reason}}
    end
  end

  defp parsed_action_permission(ast) do
    {_ast, permissions} =
      Macro.prewalk(ast, [], fn
        {:use, _meta, [target | args]} = node, acc ->
          if module_name(target) == "AllbertAssist.Action" do
            {node, [action_use_permission(args) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    permissions =
      permissions
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case permissions do
      [permission] -> {:ok, permission}
      [] -> {:error, :missing_action_permission}
      many -> {:error, {:multiple_action_permissions, many}}
    end
  end

  defp action_use_permission(args) do
    args
    |> List.flatten()
    |> Enum.find_value(fn
      {:permission, permission} when is_atom(permission) -> permission
      _other -> nil
    end)
  end

  defp module_name({:__aliases__, _meta, parts}), do: Enum.map_join(parts, ".", &to_string/1)
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_module), do: nil

  defp repair_history(generated, role_packets, previous_draft) do
    new_history =
      role_packets
      |> Enum.map(fn packet ->
        packet
        |> Map.take(["role", "status", "authority", "metadata"])
        |> Map.put_new("description", Map.get(generated, "description"))
      end)

    if(previous_draft, do: previous_draft.repair_history, else: [])
    |> Kernel.++(new_history)
    |> Redactor.redact()
  end

  defp manifest_summary(manifest) do
    %{
      "target_shapes" => Map.get(manifest, "target_shapes", []),
      "modules" => Map.get(manifest, "modules", []),
      "actions" =>
        Map.get(manifest, "actions", []) |> Enum.map(&Map.take(&1, ["name", "module"])),
      "focused_test_paths" => Map.get(manifest, "focused_test_paths", [])
    }
  end

  defp normalize_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_list(_values), do: []

  defp role_summary(role_packets) do
    Enum.map(role_packets, &Map.take(&1, ["role", "status", "authority"]))
  end

  defp ensure_repairable_draft(%Draft{producer: producer}) when producer != "codegen_llm" do
    {:error, {:dynamic_codegen_repair_not_supported, producer}}
  end

  defp ensure_repairable_draft(%Draft{tier: tier}) when tier in ["integrated", "discarded"] do
    {:error, {:draft_tier_not_repairable, tier}}
  end

  defp ensure_repairable_draft(%Draft{}), do: :ok

  defp repair_gap(%Draft{} = draft, manifest, context) do
    attrs = %{
      slug: draft.slug,
      summary:
        get_in(manifest, ["generation", "description"]) ||
          "Repair generated action #{draft.slug}",
      source: "operator",
      target_shapes: draft.target_shapes,
      objective_id: context_value(context, :objective_id),
      step_id: context_value(context, :step_id)
    }

    CapabilityGap.new(attrs, Map.put(context, :explicit_generation?, true))
  end

  defp current_generated(%Draft{} = draft, manifest) do
    with {:ok, source_path} <- manifest_source_path(manifest, "files"),
         {:ok, test_path} <- manifest_source_path(manifest, "tests"),
         {:ok, source_abs} <- safe_join(draft.root, source_path),
         {:ok, test_abs} <- safe_join(draft.root, test_path),
         {:ok, source} <- File.read(source_abs),
         {:ok, test_source} <- File.read(test_abs) do
      {:ok,
       %{
         "action_name" => get_in(manifest, ["actions", Access.at(0), "name"]) || "",
         "description" => get_in(manifest, ["generation", "description"]) || "",
         "source" => source,
         "test_source" => test_source,
         "notes" => []
       }}
    else
      {:error, reason} -> {:error, {:dynamic_codegen_current_source_unavailable, reason}}
    end
  end

  defp manifest_source_path(manifest, key) do
    case get_in(manifest, [key, Access.at(0), "source_path"]) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _other -> {:error, {:manifest_source_path_missing, key}}
    end
  end

  defp archive_revision(%Draft{} = draft, manifest) do
    archive_root = Path.join([draft.root, "revisions", draft.revision])

    with :ok <- File.mkdir_p(archive_root),
         :ok <-
           copy_if_regular(
             Path.join(draft.root, @metadata_file),
             Path.join(archive_root, @metadata_file)
           ),
         :ok <-
           copy_if_regular(
             Path.join(draft.root, @manifest_file),
             Path.join(archive_root, @manifest_file)
           ),
         :ok <- archive_source_files(draft, manifest, archive_root) do
      :ok
    end
  end

  defp archive_source_files(%Draft{} = draft, manifest, archive_root) do
    paths =
      (Map.keys(draft.source_hashes) ++
         manifest_paths(manifest, "files") ++
         manifest_paths(manifest, "tests"))
      |> Enum.uniq()

    Enum.reduce_while(paths, :ok, fn relative_path, :ok ->
      with {:ok, source} <- safe_join(draft.root, relative_path),
           target <- Path.join(archive_root, relative_path),
           :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- copy_if_regular(source, target) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp manifest_paths(manifest, key) do
    manifest
    |> Map.get(key, [])
    |> Enum.map(&(Map.get(&1, "source_path") || Map.get(&1, :source_path)))
    |> Enum.filter(&is_binary/1)
  end

  defp copy_if_regular(source, target) do
    if File.regular?(source), do: File.cp(source, target), else: :ok
  end

  defp safe_join(root, relative_path) when is_binary(root) and is_binary(relative_path) do
    path = Path.expand(relative_path, root)
    root = Path.expand(root)

    if path == root or String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, {:path_escape, relative_path}}
    end
  end

  defp gate_for(nil), do: %{"status" => "not_run", "sandbox_report_id" => nil}

  defp gate_for(%Draft{} = previous) do
    %{
      "status" => "not_run",
      "sandbox_report_id" => nil,
      "repaired_from_revision" => previous.revision,
      "previous_reports" => Map.get(previous.gate, "reports", [])
    }
  end

  defp put_draft_opts(nil), do: []

  defp put_draft_opts(%Draft{} = previous) do
    case DateTime.from_iso8601(Map.get(previous.timestamps, "updated_at", "")) do
      {:ok, previous_time, _offset} -> [now: DateTime.add(previous_time, 1, :second)]
      _other -> []
    end
  end

  defp bounded_evidence(nil), do: nil

  defp bounded_evidence(evidence) do
    evidence
    |> Redactor.redact()
    |> inspect(limit: 20, printable_limit: 2_000)
  end
end
