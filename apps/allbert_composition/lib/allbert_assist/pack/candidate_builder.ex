defmodule AllbertAssist.Pack.CandidateBuilder do
  @moduledoc """
  Composition-owned, fail-closed envelope for independently assembled Pack candidates.

  It owns input envelope validation and the mandatory two-pass canonical-byte
  stability proof. Row-family adapters supply all behavioral rows through the
  explicit `RowFamilies` contract; a missing adapter never yields a candidate.
  """

  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot

  alias AllbertAssist.Pack.{
    Canonical,
    Compatibility,
    Contribution,
    Order,
    Owner,
    ValidationDiagnostic
  }

  alias AllbertAssist.Pack.CandidateBuilder.RowFamilies

  alias AllbertAssist.Pack.CandidateBuilder.{
    ActionAssembly,
    ChannelRows,
    CompatibilityEvidence,
    MetadataRows
  }

  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.Registry.Candidate
  alias AllbertAssist.Plugin.Registry.MetadataSnapshot, as: PluginSnapshot

  @spec build(Closed.t(), AppSnapshot.t(), PluginSnapshot.t(), keyword()) ::
          {:ok, Candidate.t()} | {:error, [ValidationDiagnostic.t()]}
  def build(closed, apps, plugins, opts \\ [])

  def build(%Closed{} = closed, %AppSnapshot{} = apps, %PluginSnapshot{} = plugins, opts) do
    with :ok <- validate_snapshots(closed, apps, plugins),
         {:ok, [{first, first_bytes}, {_second, second_bytes}]} <-
           evaluate_passes(closed, apps, plugins, opts),
         true <- first_bytes == second_bytes do
      {:ok, first}
    else
      false -> {:error, [diagnostic(:candidate_capture_changed)]}
      {:error, _diagnostics} = error -> error
      _ -> {:error, [diagnostic(:invalid_candidate_input)]}
    end
  end

  def build(_closed, _apps, _plugins, _opts), do: {:error, [diagnostic(:invalid_candidate_input)]}

  defp evaluate_passes(closed, apps, plugins, opts) do
    1..2
    |> Task.async_stream(
      fn _pass ->
        with {:ok, candidate} <- evaluate(closed, apps, plugins, opts),
             {:ok, bytes} <- canonical_bytes(candidate) do
          {:ok, {candidate, bytes}}
        end
      end,
      ordered: true,
      max_concurrency: 2,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
    |> case do
      [{:ok, {:ok, first}}, {:ok, {:ok, second}}] -> {:ok, [first, second]}
      results -> pass_error(results)
    end
  end

  defp pass_error(results) do
    Enum.find_value(results, {:error, [diagnostic(:candidate_capture_failed)]}, fn
      {:ok, {:error, diagnostics}} when is_list(diagnostics) -> {:error, diagnostics}
      _other -> nil
    end)
  end

  defp evaluate(closed, apps, plugins, opts) do
    with {:ok, actions} <- ActionAssembly.build(apps.entries, plugins.entries, opts),
         {:ok, metadata} <-
           MetadataRows.build(
             closed,
             apps,
             plugins,
             Keyword.put(opts, :action_bindings, actions.bindings)
           ),
         {:ok, channels} <- ChannelRows.build(plugins.entries),
         {:ok, diagnostics} <- CompatibilityEvidence.build(plugins.entries),
         {:ok, families} <- merge_families([actions.families, metadata, channels]) do
      assemble(
        closed,
        plugins,
        families,
        actions.bindings,
        actions.aliases,
        diagnostics
      )
    end
  end

  defp assemble(closed, plugins, families, bindings, aliases, diagnostics) do
    contributions =
      Enum.map(closed.rows, &compiled_contribution(&1, families)) ++
        Enum.map(Enum.with_index(plugins.entries, 1), fn {plugin, index} ->
          plugin_contribution(plugin, index, families)
        end)

    {:ok,
     %Candidate{
       schema_version: 1,
       contributions: contributions,
       action_bindings: bindings,
       compatibility_aliases: aliases,
       compatibility_diagnostics: diagnostics
     }}
  end

  defp merge_families(families) do
    merged =
      Enum.reduce(families, RowFamilies.empty(), fn families, acc ->
        acc
        |> Map.from_struct()
        |> Map.new(fn {family, rows} ->
          {family, Map.merge(rows, Map.fetch!(families, family))}
        end)
        |> then(&struct!(RowFamilies, &1))
      end)

    if RowFamilies.valid?(merged),
      do: {:ok, merged},
      else: {:error, [diagnostic(:invalid_row_families)]}
  end

  defp compiled_contribution(projection, families) do
    %Contribution{
      schema_version: 1,
      implementation_module: projection.descriptor_module,
      owner: %Owner{
        schema_version: 1,
        kind: :compiled_pack,
        id: projection.id,
        application: projection.application
      },
      descriptor: projection.descriptor,
      source_lane: :native,
      owner_order: %Order{
        schema_version: 1,
        namespace: :compiled_pack,
        value: projection.registry_order
      },
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :native,
        legacy_id: nil,
        alias_of: nil,
        trust: :trusted,
        enabled: true
      },
      callbacks: callbacks_for(projection.id, families)
    }
  end

  defp plugin_contribution(plugin, index, families) do
    kind = if is_nil(plugin.module), do: :declared_pack, else: :legacy_plugin
    lane = if kind == :declared_pack, do: :declared, else: :legacy_plugin
    namespace = if kind == :declared_pack, do: :declared_pack, else: :legacy_plugin
    order = if kind == :declared_pack, do: plugin.plugin_id, else: index

    %Contribution{
      schema_version: 1,
      implementation_module: plugin.module,
      owner: %Owner{schema_version: 1, kind: kind, id: plugin.plugin_id, application: nil},
      descriptor: nil,
      source_lane: lane,
      owner_order: %Order{schema_version: 1, namespace: namespace, value: order},
      compatibility: %Compatibility{
        schema_version: 1,
        kind: if(kind == :declared_pack, do: :declared, else: :legacy_plugin),
        legacy_id: if(kind == :declared_pack, do: nil, else: plugin.plugin_id),
        alias_of: nil,
        trust: plugin.trust_status,
        enabled: plugin.status == :enabled
      },
      callbacks: callbacks_for(plugin.plugin_id, families)
    }
  end

  defp callbacks_for(owner_id, families),
    do: Map.new(RowFamilies.families(), &{&1, Map.get(Map.fetch!(families, &1), owner_id, [])})

  defp canonical_bytes(candidate) do
    with {:ok, snapshot} <- Canonical.build_snapshot(candidate, :shadow),
         {:ok, bytes} <- Canonical.snapshot_bytes(snapshot) do
      {:ok, bytes}
    end
  end

  defp validate_snapshots(closed, %AppSnapshot{schema_version: 1, entries: apps}, %PluginSnapshot{
         schema_version: 1,
         entries: plugins
       })
       when is_list(apps) and is_list(plugins) do
    case AllbertAssist.Pack.Projection.validate_closed(closed) do
      :ok -> :ok
      _ -> {:error, [diagnostic(:invalid_closed_projection)]}
    end
  end

  defp validate_snapshots(_closed, _apps, _plugins),
    do: {:error, [diagnostic(:invalid_metadata_snapshot)]}

  defp diagnostic(reason),
    do: %ValidationDiagnostic{
      schema_version: 1,
      code: :invalid_value,
      path: [],
      owner: nil,
      detail: %{reason: reason}
    }
end
