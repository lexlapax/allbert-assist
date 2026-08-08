defmodule AllbertAssist.Pack.CompiledInventory do
  @moduledoc """
  Reads trusted contribution owners from the compiled `allbert_assist.app` artifact.

  The OTP module inventory is release-built input. Action membership and order
  remain owned by each action module through `AllbertAssist.Action` and its
  immutable `registry_order/0` token; this module does not maintain a second
  action catalog.
  """

  alias AllbertAssist.Action

  @application :allbert_assist

  @type action_inventory_error ::
          :compiled_inventory_unavailable
          | :duplicate_action_module
          | :duplicate_compiled_module
          | :empty_action_inventory
          | :invalid_action_inventory
          | :invalid_action_module
          | :invalid_action_registry_order
          | :invalid_compiled_module
  @type action_modules_result ::
          {:ok, [module()]} | {:error, action_inventory_error()}

  @spec action_modules() :: action_modules_result()
  def action_modules do
    with {:ok, modules} <- application_modules() do
      modules
      |> Enum.filter(&catalog_action?/1)
      |> validate_action_modules()
    end
  end

  @spec plugin_modules() :: {:ok, %{String.t() => module()}} | {:error, atom()}
  def plugin_modules do
    with {:ok, modules} <- application_modules() do
      modules
      |> Enum.filter(&implements?(&1, AllbertAssist.Plugin))
      |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, plugins} ->
        with true <- function_exported?(module, :plugin_id, 0),
             plugin_id when is_binary(plugin_id) and plugin_id != "" <- module.plugin_id(),
             false <- Map.has_key?(plugins, plugin_id) do
          {:cont, {:ok, Map.put(plugins, plugin_id, module)}}
        else
          true -> {:halt, {:error, :duplicate_plugin_id}}
          _other -> {:halt, {:error, :invalid_plugin_module}}
        end
      end)
      |> case do
        {:ok, plugins} when map_size(plugins) > 0 -> {:ok, plugins}
        {:ok, _plugins} -> {:error, :empty_plugin_inventory}
        error -> error
      end
    end
  rescue
    _exception -> {:error, :invalid_plugin_module}
  catch
    _kind, _reason -> {:error, :invalid_plugin_module}
  end

  @spec default_app_modules() :: {:ok, [module()]} | {:error, atom()}
  def default_app_modules do
    with {:ok, modules} <- app_modules() do
      defaults = Enum.filter(modules, & &1.default_app?())

      if defaults == [],
        do: {:error, :empty_default_app_inventory},
        else: {:ok, defaults}
    end
  end

  @spec reserved_app_owners() :: {:ok, %{atom() => [module()]}} | {:error, atom()}
  def reserved_app_owners do
    with {:ok, modules} <- app_modules() do
      modules
      |> Enum.filter(& &1.reserved_app_id?())
      |> Enum.reduce_while({:ok, %{}}, fn module, {:ok, owners} ->
        case module.app_id() do
          app_id when is_atom(app_id) and app_id not in [nil, true, false] ->
            {:cont, {:ok, Map.update(owners, app_id, [module], &(&1 ++ [module]))}}

          _other ->
            {:halt, {:error, :invalid_reserved_app_owner}}
        end
      end)
      |> case do
        {:ok, owners} when map_size(owners) > 0 -> {:ok, owners}
        {:ok, _owners} -> {:error, :empty_reserved_app_inventory}
        error -> error
      end
    end
  rescue
    _exception -> {:error, :invalid_app_module}
  catch
    _kind, _reason -> {:error, :invalid_app_module}
  end

  @doc false
  @spec validate_action_modules([module()]) :: {:ok, [module()]} | {:error, atom()}
  def validate_action_modules(modules) when is_list(modules) do
    ordered = Enum.sort_by(modules, & &1.registry_order())
    orders = Enum.map(ordered, & &1.registry_order())
    expected = if ordered == [], do: [], else: Enum.to_list(1..length(ordered))

    cond do
      ordered == [] ->
        {:error, :empty_action_inventory}

      length(ordered) != MapSet.size(MapSet.new(ordered)) ->
        {:error, :duplicate_action_module}

      orders != expected ->
        {:error, :invalid_action_registry_order}

      true ->
        {:ok, ordered}
    end
  rescue
    _exception -> {:error, :invalid_action_module}
  catch
    _kind, _reason -> {:error, :invalid_action_module}
  end

  def validate_action_modules(_modules), do: {:error, :invalid_action_inventory}

  defp application_modules do
    case Application.spec(@application, :modules) do
      modules when is_list(modules) and modules != [] ->
        cond do
          not Enum.all?(modules, &is_atom/1) ->
            {:error, :invalid_compiled_module}

          length(modules) != MapSet.size(MapSet.new(modules)) ->
            {:error, :duplicate_compiled_module}

          true ->
            {:ok, modules}
        end

      _other ->
        {:error, :compiled_inventory_unavailable}
    end
  end

  defp app_modules do
    with {:ok, modules} <- application_modules() do
      apps =
        modules
        |> Enum.filter(fn module ->
          Code.ensure_loaded?(module) and function_exported?(module, :allbert_app?, 0) and
            module.allbert_app?() == true and function_exported?(module, :default_app?, 0) and
            function_exported?(module, :reserved_app_id?, 0)
        end)
        |> Enum.sort_by(&Atom.to_string/1)

      if apps == [], do: {:error, :empty_app_inventory}, else: {:ok, apps}
    end
  rescue
    _exception -> {:error, :invalid_app_module}
  catch
    _kind, _reason -> {:error, :invalid_app_module}
  end

  defp catalog_action?(module) do
    Action.allbert_action?(module) and function_exported?(module, :registry_order, 0) and
      is_integer(module.registry_order()) and module.registry_order() > 0
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp implements?(module, behaviour) do
    Code.ensure_loaded?(module) and
      module
      |> module_behaviours()
      |> Enum.member?(behaviour)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp module_behaviours(module) do
    module
    |> apply(:module_info, [:attributes])
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
