defmodule AllbertAssist.Intent.Router.Optimizer do
  @moduledoc """
  v0.54 M9.3c (ADR 0062) — descriptor generation + the reindex/optimize entry point.

  `optimize/1` scans agent-exposed actions that have no resolved descriptor,
  generates a candidate descriptor for each (local model when available, else a
  heuristic from the action name/description), persists it, and rebuilds the index:

    * regular static actions  -> `:generated` tier (loaded)
    * dynamic / write-code actions -> `:review` tier (inert) unless
      `intent.descriptor_autoaccept` is true (then `:generated`)

  Generation is **local-only** (no egress) and advisory — a descriptor never grants
  authority (the action's own permission/confirmation gate is unchanged).
  """
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Intent.Router.{DescriptorResolver, DescriptorStore, Index}
  alias AllbertAssist.Settings

  require Logger

  @spec optimize(keyword()) :: %{coverage: map(), generated: [String.t()], reviewed: [String.t()]}
  def optimize(opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :model)
    dynamic = dynamic_action_names()
    autoaccept = autoaccept?()

    {generated, reviewed} =
      uncovered_agent_modules()
      |> Enum.reduce({[], []}, fn module, {gen, rev} ->
        attrs = generate(module, strategy)
        tier = tier_for(module.name(), dynamic, autoaccept)
        {:ok, _path} = DescriptorStore.put(tier, attrs)
        audit(module.name(), tier, strategy)
        if tier == :generated, do: {[module.name() | gen], rev}, else: {gen, [module.name() | rev]}
      end)

    rebuild_index(opts)
    %{coverage: coverage(), generated: Enum.reverse(generated), reviewed: Enum.reverse(reviewed)}
  end

  @doc "Coverage report over the agent-exposed action surface."
  @spec coverage() :: map()
  def coverage do
    agent = agent_action_names()
    resolved = resolved_action_names()
    %{
      agent_exposed: MapSet.size(agent),
      routable: MapSet.size(MapSet.intersection(agent, resolved)),
      missing: MapSet.size(MapSet.difference(agent, resolved)),
      generated: length(DescriptorStore.read_attrs(:generated)),
      review_pending: length(DescriptorStore.read_attrs(:review)),
      overridden: length(DescriptorStore.read_attrs(:overrides))
    }
  end

  @doc """
  Generate a candidate descriptor attrs map for an action module.

  M9.3c ships the deterministic **heuristic** generator (name/description →
  label/examples/synonyms); both strategies currently produce the heuristic so the
  pipeline is offline-testable and never depends on a live model. The local-model
  enhancement (router_local via ReqLLM, ADR 0061) layers in incrementally and
  always falls back to the heuristic — generated descriptors are advisory and
  operator-curatable regardless.
  """
  @spec generate(module(), :model | :heuristic) :: map()
  def generate(module, _strategy \\ :heuristic), do: heuristic(module)

  # ── generation ───────────────────────────────────────────────────────────────

  defp heuristic(module) do
    name = module.name()
    phrase = String.replace(name, "_", " ")
    words = String.split(name, "_")

    %{
      app_id: app_id_for(name),
      action_name: name,
      label: phrase |> String.capitalize(),
      examples: Enum.uniq([phrase, "please #{phrase}"]),
      synonyms: Enum.uniq([phrase, hd(words)]),
      required_slots: [],
      handoff_required?: true
    }
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp uncovered_agent_modules do
    resolved = resolved_action_names()

    ActionsRegistry.agent_modules()
    |> Enum.reject(fn module -> MapSet.member?(resolved, module.name()) end)
  end

  defp resolved_action_names,
    do: DescriptorResolver.resolve() |> MapSet.new(& &1.action_name)

  defp agent_action_names,
    do: ActionsRegistry.agent_modules() |> MapSet.new(& &1.name())

  defp dynamic_action_names do
    ActionsOverlay.modules() |> MapSet.new(& &1.name())
  rescue
    _exception -> MapSet.new()
  catch
    :exit, _reason -> MapSet.new()
  end

  defp tier_for(name, dynamic, autoaccept) do
    cond do
      not MapSet.member?(dynamic, name) -> :generated
      autoaccept -> :generated
      true -> :review
    end
  end

  defp autoaccept? do
    case Settings.get("intent.descriptor_autoaccept") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp app_id_for(name) do
    case ActionsRegistry.capability(name) do
      {:ok, capability} -> capability.app_id || :allbert
      _other -> :allbert
    end
  rescue
    _exception -> :allbert
  end

  defp rebuild_index(opts) do
    if Keyword.get(opts, :rebuild, true), do: safe_rebuild()
  end

  defp safe_rebuild do
    Index.rebuild()
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp audit(name, tier, strategy) do
    Logger.info("[intent_descriptor_optimize] action=#{name} tier=#{tier} strategy=#{strategy}")
  end
end
