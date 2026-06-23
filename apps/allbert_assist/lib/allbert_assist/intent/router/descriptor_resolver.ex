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

  @spec resolve(keyword()) :: [Descriptor.t()]
  def resolve(opts \\ []) do
    disabled =
      if Keyword.get(opts, :ignore_disabled?, false),
        do: [],
        else: disabled_keys()

    [
      app_plugin_layer(opts),
      action_module_layer(opts),
      generated_layer(opts),
      override_layer(opts)
    ]
    |> List.flatten()
    |> dedup_later_wins()
    |> Enum.reject(fn descriptor ->
      {descriptor.app_id, descriptor.action_name} in disabled
    end)
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

  defp action_module_layer(_opts) do
    ActionsRegistry.modules()
    |> Enum.filter(&function_exported?(&1, :intent_descriptors, 0))
    |> Enum.flat_map(&descriptors_from_action_module/1)
  end

  defp descriptors_from_action_module(module) do
    module
    |> apply(:intent_descriptors, [])
    |> Descriptor.normalize_many(
      app_id: action_app_id(module),
      source: :action,
      source_module: module
    )
    |> Map.fetch!(:descriptors)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  # Core actions carry app_id: nil; descriptorize them under the reserved :allbert
  # id (Descriptor.normalize accepts the match — ADR 0062 Option 1).
  defp action_app_id(module) do
    case ActionsRegistry.capability(module.name()) do
      {:ok, capability} -> capability.app_id || :allbert
      _other -> :allbert
    end
  rescue
    _exception -> :allbert
  end

  # Accepted machine-generated descriptors (review-tier ones are NOT loaded).
  defp generated_layer(_opts), do: safe_store_load(:generated)

  # Operator-curated descriptors (highest precedence). Disabled override files are
  # disable markers only; they must not normalize into empty descriptor content
  # when callers intentionally compute an enabled candidate set.
  defp override_layer(_opts) do
    :overrides
    |> safe_store_attrs()
    |> Enum.reject(fn attrs -> truthy?(field(attrs, :disabled)) end)
    |> Descriptor.normalize_many(source: :overrides)
    |> Map.fetch!(:descriptors)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp safe_store_load(tier) do
    DescriptorStore.load(tier)
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
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

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
