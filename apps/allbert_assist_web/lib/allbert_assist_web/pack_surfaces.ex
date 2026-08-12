defmodule AllbertAssistWeb.PackSurfaces do
  @moduledoc """
  Routed web surfaces contributed by packs through `AllbertAssist.Pack.surfaces/0`.

  The read path is deliberately identical to `AllbertAssist.CLI.PackGroups`: take
  each row of the sealed projection, use its trusted `descriptor_module` atom,
  guard with `Code.ensure_loaded?/1` before `function_exported?/3`, and call the
  callback. Two mechanisms for the same job would be two things to keep true.

  `ensure_loaded?` before the export check is not defensive noise. A release loads
  modules lazily, and the bare export check answers false for a module nothing has
  forced yet — which would silently drop every contributed surface and turn a
  routed page into a 404 that looks like a routing bug.

  ## Fail closed

  A surface id that resolves to no module, an unloadable module, or one that does
  not implement the behaviour is simply absent, and the host renders its
  not-found path rather than crashing the LiveView. Two packs claiming one
  surface id are BOTH dropped and recorded: whichever won, the other pack's page
  would vanish with no diagnosis. `diagnostics/0` is empty in a sound tree and the
  gate asserts it.
  """

  alias AllbertAssist.Pack.Projection
  alias AllbertAssist.Pack.ProjectionProvider

  @cache_key {__MODULE__, :contributed}

  @typedoc "Surface id to the module that renders it."
  @type table :: %{String.t() => module()}

  @doc "Contributed surfaces, keyed by `surface_id`."
  @spec contributed() :: table()
  def contributed, do: elem(resolve(), 0)

  @doc "Rows that were rejected, as `{reason, detail}`. Empty in a sound tree."
  @spec diagnostics() :: [{atom(), term()}]
  def diagnostics, do: elem(resolve(), 1)

  @doc "Resolve one surface id to its module."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(surface_id) when is_binary(surface_id), do: Map.fetch(contributed(), surface_id)
  def fetch(_surface_id), do: :error

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

          # Not cached: unavailable is not the same as empty, and a later caller
          # with a complete code path must still be able to succeed.
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

    if Code.ensure_loaded?(module) and function_exported?(module, :surfaces, 0) do
      case module.surfaces() do
        surfaces when is_list(surfaces) -> Enum.map(surfaces, &{row.id, &1})
        other -> [{row.id, {:invalid_callback_result, other}}]
      end
    else
      []
    end
  end

  defp accumulate({pack_id, {:invalid_callback_result, value}}, {table, diagnostics}) do
    {table, [{:invalid_surfaces_result, {pack_id, value}} | diagnostics]}
  end

  defp accumulate({pack_id, surface}, {table, diagnostics}) do
    case validate(surface) do
      {:ok, surface_id, module} ->
        {Map.update(table, surface_id, module, &contested(&1, module)), diagnostics}

      {:error, reason} ->
        {table, [{reason, {pack_id, surface}} | diagnostics]}
    end
  end

  defp contested({:contested, modules}, module), do: {:contested, [module | modules]}
  defp contested(existing, module), do: {:contested, [existing, module]}

  defp reject_contested({table, diagnostics}) do
    {kept, contested} = Enum.split_with(table, fn {_id, value} -> is_atom(value) end)

    {Map.new(kept),
     Enum.reduce(contested, diagnostics, fn {surface_id, {:contested, modules}}, acc ->
       [{:contested_surface_id, {surface_id, Enum.sort(modules)}} | acc]
     end)}
  end

  defp validate(%{surface_id: surface_id, module: module})
       when is_binary(surface_id) and surface_id != "" and is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) -> {:error, :unloadable_surface_module}
      not function_exported?(module, :mount, 3) -> {:error, :surface_missing_mount}
      not function_exported?(module, :render, 1) -> {:error, :surface_missing_render}
      true -> {:ok, surface_id, module}
    end
  end

  defp validate(_surface), do: {:error, :invalid_surface_row}
end
