defmodule AllbertAssist.DynamicPlugins.Codegen.Producer do
  @moduledoc """
  Producer-neutral v0.37 draft request entrypoint.

  The v0.37.2 implementation writes source-bearing read-only action drafts
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

  @doc "Request a source-bearing read-only action draft for a normalized capability gap."
  @spec request_draft(map(), map()) :: {:ok, map()} | {:error, term()}
  def request_draft(attrs, context \\ %{}) when is_map(attrs) and is_map(context) do
    with :ok <- ensure_enabled(),
         {:ok, gap} <- CapabilityGap.new(attrs, context),
         :ok <- CapabilityGap.ensure_explicit(gap),
         {:ok, profile} <- dynamic_provider_profile(context),
         :ok <- ensure_provider_ready(profile),
         {:ok, budget} <- budget_for(attrs, gap),
         {:ok, role_packets, generated} <- Roles.run(gap, profile, budget, context),
         {:ok, budget} <- consume_budget(budget, generated),
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

  defp ensure_enabled do
    case Settings.get("dynamic_codegen.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :dynamic_codegen_disabled}
    end
  end

  defp dynamic_provider_profile(context) do
    case Settings.get("dynamic_codegen.provider_profile") do
      {:ok, name} when is_binary(name) and name != "" ->
        case Settings.resolve_model_profile(name, context) do
          {:ok, profile} -> {:ok, profile}
          {:error, :not_found} -> {:error, {:dynamic_codegen_provider_profile_not_found, name}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :missing_dynamic_codegen_provider_profile}
    end
  end

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

  defp consume_budget(budget, generated) do
    calls_used = Map.get(budget, "provider_calls_used", 0) + 1
    usage_used = Map.get(budget, "provider_usage_units_used", 0) + usage_units(generated)

    cond do
      calls_used > Map.get(budget, "provider_calls_budget", calls_used) ->
        {:error,
         {:dynamic_codegen_budget_exhausted,
          %{
            "budget" => "provider_calls",
            "requested" => calls_used,
            "limit" => Map.get(budget, "provider_calls_budget")
          }}}

      is_integer(Map.get(budget, "provider_usage_units_budget")) and
          usage_used > Map.get(budget, "provider_usage_units_budget") ->
        {:error,
         {:dynamic_codegen_budget_exhausted,
          %{
            "budget" => "provider_usage_units",
            "requested" => usage_used,
            "limit" => Map.get(budget, "provider_usage_units_budget")
          }}}

      true ->
        {:ok,
         budget
         |> Map.put("provider_calls_used", calls_used)
         |> Map.put("provider_usage_units_used", usage_used)}
    end
  end

  defp write_draft(%CapabilityGap{} = gap, profile, budget, generated, role_packets) do
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

    with :ok <- write_file(source_abs, source),
         :ok <- write_file(test_abs, test_source),
         {:ok, source_hash} <- MetadataStore.hash_file(source_abs),
         {:ok, test_hash} <- MetadataStore.hash_file(test_abs),
         manifest <-
           manifest(
             gap,
             module,
             action_name,
             source_rel,
             source_compiled,
             test_rel,
             test_compiled,
             generated,
             role_packets
           ),
         {:ok, draft} <-
           DynamicPlugins.put_draft(%{
             slug: gap.slug,
             producer: "codegen_llm",
             provider_profile: profile.name,
             target_shapes: gap.target_shapes,
             source_hashes: %{source_rel => source_hash, test_rel => test_hash},
             compiled_paths: [source_compiled, test_compiled],
             scan_paths: [source_rel, test_rel],
             budget: budget,
             diagnostics: diagnostics(gap, profile, generated, role_packets),
             repair_history: repair_history(generated, role_packets),
             static_validation: %{"status" => "not_run"},
             gate: %{"status" => "not_run", "sandbox_report_id" => nil}
           }),
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

  defp diagnostics(%CapabilityGap{} = gap, profile, generated, role_packets) do
    [
      %{
        "source" => "dynamic_codegen",
        "status" => "source_generated",
        "message" =>
          "Read-only action draft source generated; live authority remains unavailable until sandbox gate and explicit integration.",
        "gap_id" => gap.id,
        "provider_profile" => profile.name,
        "authority" => "none",
        "notes" => normalize_list(Map.get(generated, "notes")),
        "roles" => role_summary(role_packets)
      }
    ]
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

  defp usage_units(generated) do
    cond do
      is_integer(Map.get(generated, "usage_units")) ->
        Map.get(generated, "usage_units")

      is_integer(get_in(generated, ["usage", "total_tokens"])) ->
        get_in(generated, ["usage", "total_tokens"])

      is_integer(get_in(generated, ["usage", :total_tokens])) ->
        get_in(generated, ["usage", :total_tokens])

      is_integer(get_in(generated, [:usage, :total_tokens])) ->
        get_in(generated, [:usage, :total_tokens])

      true ->
        0
    end
  end

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

  defp manifest(
         gap,
         module,
         action_name,
         source_rel,
         source_compiled,
         test_rel,
         test_compiled,
         generated,
         role_packets
       ) do
    %{
      "target_shapes" => ["action"],
      "modules" => [module],
      "actions" => [
        %{
          "name" => action_name,
          "module" => module,
          "permission" => "read_only",
          "exposure" => "internal"
        }
      ],
      "files" => [
        %{"source_path" => source_rel, "compiled_path" => source_compiled}
      ],
      "tests" => [
        %{"source_path" => test_rel, "compiled_path" => test_compiled}
      ],
      "focused_test_paths" => [test_compiled],
      "generation" => %{
        "gap_id" => gap.id,
        "description" => Map.get(generated, "description"),
        "notes" => normalize_list(Map.get(generated, "notes")),
        "roles" => role_summary(role_packets)
      }
    }
  end

  defp repair_history(generated, role_packets) do
    role_packets
    |> Enum.map(fn packet ->
      packet
      |> Map.take(["role", "status", "authority", "metadata"])
      |> Map.put_new("description", Map.get(generated, "description"))
    end)
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
end
