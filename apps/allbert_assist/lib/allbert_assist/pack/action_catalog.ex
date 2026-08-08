defmodule AllbertAssist.Pack.ActionCatalog do
  @moduledoc """
  Reconstructs Pack-owned action declarations from compiled owner metadata.

  The residual boundary is the highest ordered compiled action not claimed by
  a shipped Plugin. Earlier Plugin claims are compatibility aliases; later
  claims are Plugin-owned effective actions. This reproduces the frozen
  static-first order without a central module list or numeric denominator.
  """

  alias AllbertAssist.Pack.CompiledInventory

  @spec compiled_modules() :: {:ok, [module()]} | {:error, atom()}
  def compiled_modules, do: CompiledInventory.action_modules()

  @spec residual_modules() :: {:ok, [module()]} | {:error, atom()}
  def residual_modules do
    with {:ok, actions} <- compiled_modules(),
         {:ok, plugin_modules} <- CompiledInventory.plugin_modules(),
         {:ok, declarations} <- plugin_action_declarations(plugin_modules),
         {:ok, boundary} <- residual_boundary(actions, declarations),
         :ok <- validate_partition(actions, declarations, boundary) do
      {:ok, Enum.take_while(actions, &(&1.registry_order() <= boundary))}
    end
  end

  defp plugin_action_declarations(plugin_modules) do
    plugin_modules
    |> Map.values()
    |> Enum.reduce_while({:ok, []}, fn plugin, {:ok, modules} ->
      case plugin.actions() do
        actions when is_list(actions) ->
          if Enum.all?(actions, &is_atom/1),
            do: {:cont, {:ok, modules ++ actions}},
            else: {:halt, {:error, :invalid_plugin_action_declarations}}

        _other ->
          {:halt, {:error, :invalid_plugin_action_declarations}}
      end
    end)
    |> case do
      {:ok, declarations} -> {:ok, MapSet.new(declarations)}
      error -> error
    end
  rescue
    _exception -> {:error, :invalid_plugin_action_declarations}
  catch
    _kind, _reason -> {:error, :invalid_plugin_action_declarations}
  end

  defp residual_boundary(actions, declarations) do
    actions
    |> Enum.reject(&MapSet.member?(declarations, &1))
    |> Enum.map(& &1.registry_order())
    |> Enum.max(fn -> nil end)
    |> case do
      boundary when is_integer(boundary) and boundary > 0 -> {:ok, boundary}
      _other -> {:error, :missing_residual_action_boundary}
    end
  end

  defp validate_partition(actions, declarations, boundary) do
    action_set = MapSet.new(actions)

    cond do
      not MapSet.subset?(declarations, action_set) ->
        {:error, :uncompiled_plugin_action}

      Enum.any?(actions, fn module ->
        module.registry_order() > boundary and not MapSet.member?(declarations, module)
      end) ->
        {:error, :unowned_compiled_action}

      true ->
        :ok
    end
  end
end
