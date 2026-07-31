defmodule AllbertAssist.Intent.Router.DescriptorResolver do
  @moduledoc """
  v0.54 M9.3 (ADR 0062) — the layered descriptor set the router `Index` builds from.

  Merges, deduped by `{app_id, action_name}` with **later layers winning**
  (mirrors `Settings.Store` `deep_merge(defaults, overrides)`):

    1. **app/plugin-module** — existing `intent_descriptors/0` on app/plugin app
       modules (`Extensions.Registry.registered_intent_descriptors/0`).
    2. **action-module** — `intent_descriptors/0` co-located on action modules
       (a new scan; core actions resolve under the reserved `:allbert` id).
    3. **generated** — local-model descriptors for actions lacking one (M9.3c;
       currently a stub returning `[]`).
    4. **operator override** — operator-curated md/yaml (M9.4; stub `[]`).

  The merge is advisory-only: it changes *which* candidates the router shortlists,
  never *whether* an action may run (the runner + Security Central + confirmation
  gate are unchanged).
  """
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Maps
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Settings

  # F5 Q2: intents whose backing capability is operator-toggled; when the setting is off
  # the capability is unavailable, so the intent must not be routable (e.g. "Say hello"
  # was routing to synthesize_voice → denied :voice_disabled).
  @capability_gated_settings %{
    "synthesize_voice" => "voice.enabled",
    "transcribe_voice" => "voice.enabled",
    "capture_workspace_voice" => "voice.enabled"
  }

  @spec resolve(keyword()) :: [Descriptor.t()]
  def resolve(opts \\ []) do
    ignore_disabled? = Keyword.get(opts, :ignore_disabled?, false)
    # Operator-disable overrides are honored unless the caller explicitly ignores them.
    disabled = if ignore_disabled?, do: [], else: disabled_keys()
    # Deterministic eval explicitly includes capability-gated and demo descriptors. It
    # remains distinct from `ignore_disabled?: true`: operator-authored disable overrides
    # still win, as do active generated/override descriptor contents.
    gate_bypass? =
      ignore_disabled? or Keyword.get(opts, :availability) == :deterministic_eval or
        include_all_descriptors?()

    canonical = dedup_later_wins(app_plugin_layer(opts) ++ action_module_layer(opts))
    with_generated = merge_stored_layer(canonical, :generated)

    with_generated
    |> merge_stored_layer(:overrides)
    |> Enum.reject(fn descriptor ->
      {descriptor.app_id, descriptor.action_name} in disabled
    end)
    |> reject_unavailable(gate_bypass?)
  end

  # F5 Q2 + Q3: on a fresh/production install, drop intents whose capability is toggled off
  # (voice) and demo/example intents (StockSage `routable_by_default?: false`) so general
  # prompts are not mis-routed to them. Bypassed for tests/evals.
  defp reject_unavailable(descriptors, true), do: descriptors

  defp reject_unavailable(descriptors, false) do
    Enum.reject(descriptors, fn descriptor ->
      demo_intent?(descriptor) or capability_gated_off?(descriptor)
    end)
  end

  defp demo_intent?(%Descriptor{routable_by_default?: false}), do: true
  defp demo_intent?(_descriptor), do: false

  defp capability_gated_off?(%Descriptor{action_name: action_name}) do
    case Map.get(@capability_gated_settings, to_string(action_name)) do
      nil -> false
      setting_key -> Settings.get(setting_key) != {:ok, true}
    end
  end

  defp include_all_descriptors? do
    Application.get_env(:allbert_assist, :intent_descriptor_include_all, false) == true
  end

  # Operator overrides may mark an action non-routable with `%{..., disabled: true}`.
  defp disabled_keys do
    safe_store_attrs(:overrides)
    |> Enum.filter(fn attrs -> truthy?(field(attrs, :disabled)) end)
    |> Enum.map(fn attrs ->
      {normalize_app_id(field(attrs, :app_id)), to_string(field(attrs, :action_name))}
    end)
  end

  # ── layers ───────────────────────────────────────────────────────────────────

  defp app_plugin_layer(opts), do: ExtensionsRegistry.registered_intent_descriptors(opts)

  defp action_module_layer(opts) do
    registry = RegistryContext.take(opts)

    registry
    |> ActionsRegistry.modules()
    |> Enum.filter(&function_exported?(&1, :intent_descriptors, 0))
    |> Enum.flat_map(&descriptors_from_action_module(&1, registry))
  end

  defp descriptors_from_action_module(module, registry) do
    module
    |> apply(:intent_descriptors, [])
    |> Descriptor.normalize_many(
      [
        app_id: action_app_id(module, registry),
        source: :action,
        source_module: module
      ] ++ registry
    )
    |> Map.fetch!(:descriptors)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  # Core actions carry app_id: nil; descriptorize them under the reserved :allbert
  # id (Descriptor.normalize accepts the match — ADR 0062 Option 1).
  defp action_app_id(module, registry) do
    case ActionsRegistry.capability(module.name(), registry) do
      {:ok, capability} -> capability.app_id || :allbert
      _other -> :allbert
    end
  rescue
    _exception -> :allbert
  end

  # Stored descriptors replace routing language, but omitting a selection policy
  # cannot silently weaken the policy already attached to the same canonical
  # action. An explicitly supplied `semantic` remains an intentional override.
  defp merge_stored_layer(inherited, tier) do
    policies = Map.new(inherited, &{{&1.app_id, &1.action_name}, &1.selection_policy})

    stored =
      tier
      |> safe_store_attrs()
      |> Enum.reject(fn attrs -> tier == :overrides and truthy?(field(attrs, :disabled)) end)
      |> Enum.map(&inherit_omitted_selection_policy(&1, policies))
      |> Descriptor.normalize_many(source: tier)
      |> Map.fetch!(:descriptors)

    dedup_later_wins(inherited ++ stored)
  rescue
    _exception -> inherited
  catch
    :exit, _reason -> inherited
  end

  defp inherit_omitted_selection_policy(attrs, policies) do
    if Map.has_key?(attrs, :selection_policy) or Map.has_key?(attrs, "selection_policy") do
      attrs
    else
      key = {normalize_app_id(field(attrs, :app_id)), to_string(field(attrs, :action_name))}

      case Map.fetch(policies, key) do
        {:ok, policy} -> Map.put(attrs, :selection_policy, policy)
        :error -> attrs
      end
    end
  end

  defp safe_store_attrs(tier) do
    DescriptorStore.read_attrs(tier)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  # ── dedup ────────────────────────────────────────────────────────────────────

  # Keep the LAST descriptor for each {app_id, action_name} so later layers win,
  # preserving first-seen order otherwise.
  defp dedup_later_wins(descriptors) do
    {_seen, reversed} =
      descriptors
      |> Enum.reverse()
      |> Enum.reduce({MapSet.new(), []}, fn descriptor, {seen, acc} ->
        key = {descriptor.app_id, descriptor.action_name}

        if MapSet.member?(seen, key) do
          {seen, acc}
        else
          {MapSet.put(seen, key), [descriptor | acc]}
        end
      end)

    reversed
  end

  defp normalize_app_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_app_id(value), do: value

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
