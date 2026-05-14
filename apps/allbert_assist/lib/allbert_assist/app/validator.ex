defmodule AllbertAssist.App.Validator do
  @moduledoc false

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry

  @required_exports [
    app_id: 0,
    display_name: 0,
    version: 0,
    validate: 1,
    child_spec: 1,
    actions: 0,
    skill_paths: 0
  ]

  @app_id_regex ~r/^[a-z][a-z0-9_]*$/
  @reserved_nil_aliases [:none, :general]
  @reserved_app_owners %{
    allbert: [AllbertAssist.App.CoreApp],
    stocksage: [AllbertAssist.App.StockSageStub, StockSage.App]
  }

  @type result :: {:ok, map()} | {:error, {atom(), term()}, [map()]}

  @spec validate(module(), keyword() | map()) :: result()
  def validate(module, opts \\ []) do
    with {:ok, module} <- validate_module(module),
         {:ok, app_id} <- validate_app_id(module),
         {:ok, display_name} <- validate_string(module, :display_name, 64),
         {:ok, version} <- validate_string(module, :version, 32),
         :ok <- run_app_validation(module, opts),
         {:ok, actions} <- validate_actions(module),
         {:ok, skill_paths} <- validate_skill_paths(module),
         {:ok, surfaces} <- validate_surfaces(module, app_id) do
      {:ok,
       %{
         app_id: app_id,
         module: module,
         display_name: display_name,
         version: version,
         actions: actions,
         skill_paths: skill_paths,
         surfaces: surfaces
       }}
    else
      {:error, reason, diagnostics} -> {:error, reason, diagnostics}
      {:error, reason} -> {:error, reason, [diagnostic(reason)]}
    end
  rescue
    exception ->
      reason = {:validation_raised, module}
      {:error, reason, [diagnostic(reason, Exception.message(exception))]}
  end

  defp validate_module(module) when is_atom(module) do
    loaded? = Code.ensure_loaded?(module)

    exports? =
      loaded? and
        Enum.all?(@required_exports, fn {name, arity} ->
          function_exported?(module, name, arity)
        end)

    cond do
      not loaded? -> {:error, {:invalid_module, module}}
      not exports? -> {:error, {:invalid_module, module}}
      true -> {:ok, module}
    end
  end

  defp validate_module(module), do: {:error, {:invalid_module, module}}

  defp validate_app_id(module) do
    app_id = module.app_id()
    string = if is_atom(app_id), do: Atom.to_string(app_id), else: nil

    cond do
      not is_atom(app_id) ->
        {:error, {:invalid_app_id, module}}

      is_nil(app_id) or app_id in @reserved_nil_aliases ->
        {:error, {:reserved_app_id, app_id}}

      not Regex.match?(@app_id_regex, string) ->
        {:error, {:invalid_app_id, app_id}}

      reserved_for_other_module?(app_id, module) ->
        {:error, {:reserved_app_id, app_id}}

      true ->
        {:ok, app_id}
    end
  end

  defp reserved_for_other_module?(app_id, module) do
    case Map.get(@reserved_app_owners, app_id) do
      nil -> false
      owners -> module not in owners
    end
  end

  defp validate_string(module, callback, max_length) do
    value =
      module
      |> apply(callback, [])
      |> normalize_string()

    if is_binary(value) and byte_size(value) in 1..max_length do
      {:ok, value}
    else
      {:error, {:invalid_metadata, callback}}
    end
  end

  defp run_app_validation(module, opts) do
    case module.validate(opts) do
      :ok ->
        :ok

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, {:validation_failed, module}, normalize_diagnostics(diagnostics)}

      other ->
        {:error, {:validation_failed, module}, [diagnostic({:invalid_validation_result, other})]}
    end
  rescue
    exception ->
      {:error, {:validation_raised, module},
       [diagnostic({:validation_raised, module}, Exception.message(exception))]}
  end

  defp validate_actions(module) do
    case module.actions() do
      actions when is_list(actions) ->
        validate_action_modules(actions, [])

      _other ->
        {:error, {:invalid_actions, module}}
    end
  end

  defp validate_action_modules([], acc), do: {:ok, Enum.reverse(acc)}

  defp validate_action_modules([action | rest], acc) do
    with :ok <- validate_action_module(action) do
      validate_action_modules(rest, [action | acc])
    end
  end

  defp validate_action_module(action) when is_atom(action) do
    case ActionsRegistry.resolve(action) do
      {:ok, ^action} -> :ok
      _error -> {:error, {:unknown_action_module, action}}
    end
  end

  defp validate_action_module(action), do: {:error, {:unknown_action_module, action}}

  defp validate_skill_paths(module) do
    case module.skill_paths() do
      paths when is_list(paths) ->
        validate_skill_paths(paths, [])

      _other ->
        {:error, {:invalid_skill_paths, module}}
    end
  end

  defp validate_skill_paths([], acc), do: {:ok, Enum.reverse(acc)}

  defp validate_skill_paths([path | rest], acc) do
    with :ok <- validate_skill_path(path) do
      validate_skill_paths(rest, [Path.expand(path) | acc])
    end
  end

  defp validate_skill_path(path) when is_binary(path) do
    cond do
      byte_size(path) > 256 -> {:error, {:invalid_skill_path, path}}
      Path.type(path) != :absolute -> {:error, {:invalid_skill_path, path}}
      true -> :ok
    end
  end

  defp validate_skill_path(path), do: {:error, {:invalid_skill_path, path}}

  defp validate_surfaces(module, app_id) do
    surfaces = if function_exported?(module, :surfaces, 0), do: module.surfaces(), else: []

    with true <- is_list(surfaces),
         {:ok, normalized} <- normalize_surfaces(surfaces, app_id),
         :ok <- validate_unique_surface_ids(normalized) do
      {:ok, normalized}
    else
      false -> {:error, {:invalid_surfaces, module}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_surfaces(surfaces, app_id) do
    Enum.reduce_while(surfaces, {:ok, []}, fn surface, {:ok, acc} ->
      case normalize_surface(surface, app_id) do
        {:ok, surface} -> {:cont, {:ok, [surface | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, surfaces} -> {:ok, Enum.reverse(surfaces)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_surface(%{} = surface, app_id) do
    attrs = surface_attrs(surface)

    with :ok <- validate_surface_id(attrs.id),
         :ok <- validate_surface_label(attrs.label),
         :ok <- validate_surface_path(attrs.path),
         :ok <- validate_surface_app_id(attrs.surface_app_id, app_id),
         :ok <- validate_surface_optional(attrs.icon, :icon, 64),
         :ok <- validate_surface_optional(attrs.description, :description, 256) do
      {:ok,
       %{
         id: attrs.id,
         label: attrs.label,
         path: attrs.path,
         app_id: app_id,
         icon: attrs.icon,
         description: attrs.description
       }}
    end
  end

  defp normalize_surface(_surface, _app_id), do: {:error, {:invalid_surface, :shape}}

  defp surface_attrs(surface) do
    %{
      id: field(surface, :id),
      label: normalize_string(field(surface, :label)),
      path: normalize_string(field(surface, :path)),
      surface_app_id: field(surface, :app_id),
      icon: normalize_optional_string(field(surface, :icon)),
      description: normalize_optional_string(field(surface, :description))
    }
  end

  defp validate_surface_id(id) when is_atom(id) and not is_nil(id), do: :ok
  defp validate_surface_id(_id), do: {:error, {:invalid_surface, :id}}

  defp validate_surface_label(label) when is_binary(label) and byte_size(label) in 1..64,
    do: :ok

  defp validate_surface_label(_label), do: {:error, {:invalid_surface, :label}}

  defp validate_surface_path(path) do
    if valid_surface_path?(path), do: :ok, else: {:error, {:invalid_surface, :path}}
  end

  defp validate_surface_app_id(app_id, app_id), do: :ok

  defp validate_surface_app_id(_surface_app_id, _app_id),
    do: {:error, {:invalid_surface, :app_id}}

  defp validate_surface_optional(value, _kind, max)
       when is_binary(value) and byte_size(value) <= max,
       do: :ok

  defp validate_surface_optional(nil, _kind, _max), do: :ok
  defp validate_surface_optional(_value, kind, _max), do: {:error, {:invalid_surface, kind}}

  defp validate_unique_surface_ids(surfaces) do
    duplicates =
      surfaces
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)

    if duplicates == [], do: :ok, else: {:error, {:invalid_surface, :duplicate_id}}
  end

  defp valid_surface_path?(path) when is_binary(path) do
    byte_size(path) in 1..128 and String.starts_with?(path, "/") and
      not String.contains?(path, ["?", "#"]) and not Regex.match?(~r/\s/, path)
  end

  defp valid_surface_path?(_path), do: false

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: nil

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_diagnostics(diagnostics), do: Enum.map(diagnostics, &normalize_diagnostic/1)

  defp normalize_diagnostic(%{} = diagnostic) do
    %{
      kind: field(diagnostic, :kind) || :validation_failed,
      message: to_string(field(diagnostic, :message) || "Validation failed."),
      detail: field(diagnostic, :detail) || %{}
    }
  end

  defp normalize_diagnostic(diagnostic),
    do: %{kind: :validation_failed, message: inspect(diagnostic), detail: %{}}

  defp diagnostic(reason, message \\ nil) do
    %{
      kind: reason_kind(reason),
      message: message || reason_message(reason),
      detail: %{reason: inspect(reason)}
    }
  end

  defp reason_kind({kind, _detail}) when is_atom(kind), do: kind
  defp reason_kind(kind) when is_atom(kind), do: kind
  defp reason_kind(_reason), do: :invalid_app

  defp reason_message({kind, detail}), do: "#{kind}: #{inspect(detail)}"
  defp reason_message(reason), do: inspect(reason)

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
