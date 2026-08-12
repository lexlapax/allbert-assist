defmodule AllbertAssist.CLI.PackGroups do
  @moduledoc """
  Command groups contributed by packs through `AllbertAssist.Pack.cli_groups/0`.

  ## Why this exists

  `AllbertAssist.CLI.Commands` holds a compile-time table, which is correct for
  an area compiled into the residual and wrong for one owned by a pack. Before
  v1.4 M12 a pack could not own its command surface at all: the already-extracted
  notes_files pack had its area sitting in the residual, hand-registered in that
  table. `cli_groups/0` existed with a frozen row schema and a slot in the
  canonical digest, but nothing produced or consumed a row, so extracting the
  Telegram and email channels would have left the residual calling into a pack —
  the return edge the R0 frozen DAG forbids.

  ## Read path

  The projection's rows carry a trusted `descriptor_module` atom, and this reads
  `cli_groups/0` from it directly. That is deliberately the same shape
  `AllbertAssist.Settings.Fragments.pack_contributions/1` uses for
  `settings_fragments`: another consumed callback whose canonical rows are
  likewise empty because no candidate-builder adapter populates them. Adding a
  second, different mechanism for the same job is the cost this avoids.

  ## Fail closed

  A pack cannot shadow a built-in command. That guarantee does not live here —
  `Commands.operator_table/0` merges this map UNDER its own literal table, so a
  colliding contributed path is structurally unreachable rather than rejected by
  a check that could be reordered away. What this module does is refuse to
  produce a row it cannot fully validate: an unloadable module, one that does not
  export `dispatch/2`, a malformed path, or a path two packs both claim. Those
  are dropped and recorded in `diagnostics/0` rather than raised, because a
  packaging fault should cost one unknown command, not every command. The gate
  asserts `diagnostics/0` is empty.

  An unavailable projection yields no groups and is not cached, so a caller that
  runs before the code path is complete does not freeze an empty table.
  """

  alias AllbertAssist.Pack.Projection
  alias AllbertAssist.Pack.ProjectionProvider

  @cache_key {__MODULE__, :contributed}

  @typedoc "A resolved contributed group: dispatch path to area disposition."
  @type table :: %{[String.t()] => {:area, module()}}

  @doc """
  Contributed groups, keyed by dispatch path.

  Cached in `:persistent_term` because the CLI resolves the table two to four
  times per invocation and each build reads the component catalog and
  reconciles the projection.
  """
  @spec contributed() :: table()
  def contributed, do: elem(resolve(), 0)

  @doc "Rows that were rejected, as `{reason, detail}` pairs. Empty in a sound tree."
  @spec diagnostics() :: [{atom(), term()}]
  def diagnostics, do: elem(resolve(), 1)

  @doc "Drop the cache. Tests that install a different projection call this."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp resolve do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        case ProjectionProvider.closed() do
          {:ok, closed} ->
            resolved = build(closed)
            :persistent_term.put(@cache_key, resolved)
            resolved

          # Not cached: the projection is unavailable rather than empty, and a
          # later caller with a complete code path must be able to succeed.
          {:error, reason} ->
            {%{}, [{:projection_unavailable, reason}]}
        end

      resolved ->
        resolved
    end
  end

  defp build(%Projection.Closed{rows: rows}) do
    rows
    |> Enum.sort_by(&{&1.registry_order, &1.id})
    |> Enum.flat_map(&rows_for/1)
    |> Enum.reduce({%{}, []}, &accumulate/2)
    |> reject_contested()
  end

  defp rows_for(row) do
    module = row.descriptor_module

    # `ensure_loaded?` before `function_exported?`, which answers false for a
    # module that simply has not been loaded yet. The CLI resolves this table
    # while planning the entry, before anything has forced a pack's descriptor
    # module, so the bare export check would silently drop every contributed
    # group in a release and only work in a test VM that had already loaded it.
    if Code.ensure_loaded?(module) and function_exported?(module, :cli_groups, 0) do
      case module.cli_groups() do
        groups when is_list(groups) -> Enum.map(groups, &{row.id, &1})
        other -> [{row.id, {:invalid_callback_result, other}}]
      end
    else
      # Absent rather than empty is legitimate: the callback is optional, and a
      # pack that contributes no CLI simply does not export it.
      []
    end
  end

  defp accumulate({pack_id, {:invalid_callback_result, value}}, {table, diagnostics}) do
    {table, [{:invalid_cli_groups_result, {pack_id, value}} | diagnostics]}
  end

  defp accumulate({pack_id, group}, {table, diagnostics}) do
    case validate(group) do
      {:ok, path, module} ->
        {Map.update(table, path, {:area, module}, fn existing ->
           contested(existing, module)
         end), diagnostics}

      {:error, reason} ->
        {table, [{reason, {pack_id, group}} | diagnostics]}
    end
  end

  # Two packs claiming one path is not resolvable by ordering: whichever wins,
  # the other pack's command silently disappears. Both are dropped.
  defp contested({:area, existing}, module), do: {:contested, [existing, module]}
  defp contested({:contested, modules}, module), do: {:contested, [module | modules]}

  defp reject_contested({table, diagnostics}) do
    {kept, contested} =
      Enum.split_with(table, fn
        {_path, {:area, _module}} -> true
        {_path, {:contested, _modules}} -> false
      end)

    {Map.new(kept),
     Enum.reduce(contested, diagnostics, fn {path, {:contested, modules}}, acc ->
       [{:contested_command_path, {path, Enum.sort(modules)}} | acc]
     end)}
  end

  defp validate(%{command_path: path, module: module})
       when is_list(path) and path != [] and is_atom(module) do
    cond do
      not Enum.all?(path, &(is_binary(&1) and &1 != "")) ->
        {:error, :invalid_command_path}

      not Code.ensure_loaded?(module) ->
        {:error, :unloadable_cli_module}

      not function_exported?(module, :dispatch, 2) ->
        {:error, :cli_module_missing_dispatch}

      true ->
        {:ok, path, module}
    end
  end

  defp validate(_group), do: {:error, :invalid_cli_group_row}
end
