defmodule AllbertAssist.Pack.ActionCatalog do
  @moduledoc """
  Reconstructs Pack-owned action declarations from compiled owner metadata.

  The residual boundary is the highest ordered compiled action not claimed by
  a shipped Plugin. Earlier Plugin claims are compatibility aliases; later
  claims are Plugin-owned effective actions. This reproduces the frozen
  static-first order without a central module list or numeric denominator.
  """

  alias AllbertAssist.{Action, Actions.Capability}
  alias AllbertAssist.Pack.CompiledInventory

  @spec compiled_modules() :: CompiledInventory.action_modules_result()
  def compiled_modules, do: CompiledInventory.action_modules()

  @spec capability(module() | String.t() | atom()) ::
          {:ok, Capability.t()} | {:error, {:unknown_action, term()}}
  def capability(action) do
    with {:ok, modules} <- compiled_modules(),
         module when is_atom(module) <- find_module(modules, action),
         {:ok, attrs} <- Action.validate_capability(module.capability()) do
      {:ok, Capability.new(module, attrs)}
    else
      _other -> {:error, {:unknown_action, action}}
    end
  rescue
    _exception -> {:error, {:unknown_action, action}}
  catch
    _kind, _reason -> {:error, {:unknown_action, action}}
  end

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
    |> Enum.reduce_while({:ok, []}, &collect_plugin_actions/2)
    |> case do
      {:ok, declarations} -> {:ok, MapSet.new(declarations)}
      error -> error
    end
  rescue
    _exception -> {:error, :invalid_plugin_action_declarations}
  catch
    _kind, _reason -> {:error, :invalid_plugin_action_declarations}
  end

  defp collect_plugin_actions(plugin, {:ok, modules}) do
    case plugin.actions() do
      actions when is_list(actions) ->
        if Enum.all?(actions, &is_atom/1) do
          {:cont, {:ok, modules ++ actions}}
        else
          {:halt, {:error, :invalid_plugin_action_declarations}}
        end

      _other ->
        {:halt, {:error, :invalid_plugin_action_declarations}}
    end
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

  defp find_module(modules, action) when is_atom(action) do
    Enum.find(modules, fn module ->
      module == action or normalize_name(module.name()) == normalize_name(Atom.to_string(action))
    end)
  end

  defp find_module(modules, action) when is_binary(action) do
    normalized = normalize_name(action)
    Enum.find(modules, &(normalize_name(&1.name()) == normalized))
  end

  defp find_module(_modules, _action), do: nil

  defp normalize_name(name) do
    name
    |> String.replace_prefix("Elixir.", "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
