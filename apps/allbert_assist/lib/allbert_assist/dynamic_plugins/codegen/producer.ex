defmodule AllbertAssist.DynamicPlugins.Codegen.Producer do
  @moduledoc """
  Producer-neutral v0.37 draft request entrypoint.

  The shipped v0.37 implementation records inert draft metadata after explicit
  operator/objective requests pass settings, provider-profile, and budget
  checks. It intentionally does not call a provider, write live modules, trust
  output, run gates, or integrate actions.
  """

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.Codegen.Budget
  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.Objectives
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @doc "Request an inert dynamic draft for a normalized capability gap."
  @spec request_draft(map(), map()) :: {:ok, map()} | {:error, term()}
  def request_draft(attrs, context \\ %{}) when is_map(attrs) and is_map(context) do
    with :ok <- ensure_enabled(),
         {:ok, gap} <- CapabilityGap.new(attrs, context),
         :ok <- CapabilityGap.ensure_explicit(gap),
         {:ok, profile} <- dynamic_provider_profile(context),
         :ok <- ensure_provider_ready(profile),
         {:ok, budget} <- budget_for(attrs, gap),
         {:ok, draft} <- write_draft(gap, profile, budget),
         :ok <- audit_draft_requested(gap, draft, profile, budget, context),
         :ok <- record_objective_event(gap, draft, profile, budget) do
      {:ok,
       %{
         draft: Draft.summary(draft),
         gap: CapabilityGap.summary(gap),
         provider_profile: provider_summary(profile),
         budget: budget,
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

        %{enabled: true, api_key_ref: api_key_ref, credential_status: credential_status} ->
          ensure_credentials(provider, api_key_ref, credential_status)

        nil ->
          {:error, {:dynamic_codegen_unknown_provider, provider}}
      end
    end
  end

  defp ensure_provider_ready(profile), do: {:error, {:dynamic_codegen_invalid_profile, profile}}

  defp ensure_credentials(_provider, nil, _credential_status), do: :ok
  defp ensure_credentials(_provider, _api_key_ref, :configured), do: :ok

  defp ensure_credentials(provider, _api_key_ref, status) do
    {:error,
     {:dynamic_codegen_provider_credentials_missing, %{provider: provider, status: status}}}
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

  defp write_draft(%CapabilityGap{} = gap, profile, budget) do
    DynamicPlugins.put_draft(%{
      slug: gap.slug,
      producer: gap.producer,
      provider_profile: profile.name,
      target_shapes: gap.target_shapes,
      budget: budget,
      diagnostics: diagnostics(gap, profile),
      repair_history: [],
      static_validation: %{"status" => "not_run"},
      gate: %{"status" => "not_run", "sandbox_report_id" => nil}
    })
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

  defp diagnostics(%CapabilityGap{} = gap, profile) do
    [
      %{
        "source" => "dynamic_codegen",
        "status" => "draft_requested",
        "message" =>
          "Draft metadata recorded; provider generation and live authority remain unavailable until sandbox gate and explicit integration.",
        "gap_id" => gap.id,
        "provider_profile" => profile.name,
        "authority" => "none"
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
end
