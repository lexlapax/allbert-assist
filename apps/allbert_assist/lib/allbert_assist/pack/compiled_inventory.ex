defmodule AllbertAssist.Pack.CompiledInventory do
  @moduledoc """
  Reads trusted contribution owners from compiled `.app` artifacts.

  The OTP module inventory is release-built input. Action membership and order
  remain owned by each action module through `AllbertAssist.Action` and its
  immutable `registry_order/0` token; this module does not maintain a second
  action catalog.

  ## Why this reads more than one application

  Until v1.4 M9 this read `allbert_assist` alone, which was correct only while
  every contribution compiled into the residual by path injection. A pack is its
  own OTP application, so a single hardcoded application name is the same defect
  ADR 0098 catalogued as a hand-maintained kernel list — M1 deleted the
  thirteen-entry `@shipped_modules` map, but the derivation that replaced it
  still assumed one application, and the first real extraction would have
  vanished from discovery.

  The application set is therefore supplied by the caller and defaults to the
  residual, so callers that already know the descriptor-bearing applications —
  the Pack projection enumerates them — pass them, and nothing here keeps a
  roster of its own.
  """

  alias AllbertAssist.Action

  @residual_application :allbert_assist

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

  @doc """
  The applications searched when a caller supplies none.

  Every loaded application declaring an `allbert_pack` entry, which is how ADR
  0098 §4 marks a descriptor-bearing application, plus the residual. Discovering
  the set rather than listing it is the point: extracting a pack must not
  require editing a roster here, which is the defect this module previously had
  in the form of a single hardcoded application name.

  The coordinator separately validates each declaration against the raw `.app`
  term and the sealed projection; this is the search set, not an authority.
  """
  @spec default_applications() :: [atom()]
  def default_applications do
    Application.loaded_applications()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&(Application.fetch_env(&1, :allbert_pack) != :error))
    |> Enum.concat([@residual_application])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec action_modules([atom()]) :: action_modules_result()
  def action_modules(applications \\ default_applications()) do
    with {:ok, modules} <- application_modules(applications) do
      modules
      |> Enum.filter(&catalog_action?/1)
      |> validate_action_modules()
    end
  end

  @spec plugin_modules([atom()]) :: {:ok, %{String.t() => module()}} | {:error, atom()}
  def plugin_modules(applications \\ default_applications()) do
    with {:ok, modules} <- application_modules(applications) do
      modules
      |> Enum.filter(&implements?(&1, AllbertAssist.Plugin))
      |> Enum.filter(&product_plugin?/1)
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

  @spec default_app_modules([atom()]) :: {:ok, [module()]} | {:error, atom()}
  def default_app_modules(applications \\ default_applications()) do
    with {:ok, modules} <- app_modules(applications) do
      defaults = Enum.filter(modules, & &1.default_app?())

      if defaults == [],
        do: {:error, :empty_default_app_inventory},
        else: {:ok, defaults}
    end
  end

  @spec reserved_app_owners([atom()]) :: {:ok, %{atom() => [module()]}} | {:error, atom()}
  def reserved_app_owners(applications \\ default_applications()) do
    with {:ok, modules} <- app_modules(applications) do
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

  defp application_modules(applications) when is_list(applications) and applications != [] do
    with {:ok, modules} <- collect_application_modules(applications) do
      validate_compiled_modules(modules)
    end
  end

  defp application_modules(_applications), do: {:error, :compiled_inventory_unavailable}

  defp collect_application_modules(applications) do
    Enum.reduce_while(applications, {:ok, []}, fn application, {:ok, acc} ->
      case Application.spec(application, :modules) do
        modules when is_list(modules) and modules != [] -> {:cont, {:ok, acc ++ modules}}
        _other -> {:halt, {:error, :compiled_inventory_unavailable}}
      end
    end)
  end

  # A module appearing in two applications is a packaging error, not a merge to
  # resolve, so the duplicate check spans the whole set rather than each
  # application separately.
  defp validate_compiled_modules(modules) do
    cond do
      not Enum.all?(modules, &is_atom/1) -> {:error, :invalid_compiled_module}
      length(modules) != MapSet.size(MapSet.new(modules)) -> {:error, :duplicate_compiled_module}
      true -> {:ok, modules}
    end
  end

  defp app_modules(applications) do
    with {:ok, modules} <- application_modules(applications) do
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

  # Product membership is declared by the module, not inferred from the fact that
  # it implements the behaviour -- see `AllbertAssist.Plugin.product?/0` for the
  # M13 fixture that made the difference matter. A module that predates the
  # callback, or implements the behaviour without `use`, is treated as a product
  # plugin: the failure this filter must never have is silently dropping a real
  # one, and only a deliberate `product?: false` excludes anything.
  defp product_plugin?(module) do
    not function_exported?(module, :product?, 0) or module.product?()
  rescue
    _exception -> true
  catch
    _kind, _reason -> true
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
