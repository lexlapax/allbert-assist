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

      true ->
        {:ok, app_id}
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
        actions
        |> Enum.reduce_while({:ok, []}, fn action, {:ok, acc} ->
          with true <- is_atom(action),
               {:ok, resolved} <- ActionsRegistry.resolve(action),
               true <- resolved == action do
            {:cont, {:ok, [action | acc]}}
          else
            _error -> {:halt, {:error, {:unknown_action_module, action}}}
          end
        end)
        |> case do
          {:ok, actions} -> {:ok, Enum.reverse(actions)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, {:invalid_actions, module}}
    end
  end

  defp validate_skill_paths(module) do
    case module.skill_paths() do
      paths when is_list(paths) ->
        paths
        |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
          cond do
            not is_binary(path) -> {:halt, {:error, {:invalid_skill_path, path}}}
            byte_size(path) > 256 -> {:halt, {:error, {:invalid_skill_path, path}}}
            Path.type(path) != :absolute -> {:halt, {:error, {:invalid_skill_path, path}}}
            true -> {:cont, {:ok, [Path.expand(path) | acc]}}
          end
        end)
        |> case do
          {:ok, paths} -> {:ok, Enum.reverse(paths)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, {:invalid_skill_paths, module}}
    end
  end

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
    id = field(surface, :id)
    label = normalize_string(field(surface, :label))
    path = normalize_string(field(surface, :path))
    surface_app_id = field(surface, :app_id)
    icon = normalize_optional_string(field(surface, :icon))
    description = normalize_optional_string(field(surface, :description))

    cond do
      not is_atom(id) ->
        {:error, {:invalid_surface, :id}}

      not is_binary(label) or byte_size(label) == 0 or byte_size(label) > 64 ->
        {:error, {:invalid_surface, :label}}

      not valid_surface_path?(path) ->
        {:error, {:invalid_surface, :path}}

      surface_app_id != app_id ->
        {:error, {:invalid_surface, :app_id}}

      not optional_string?(icon, 64) ->
        {:error, {:invalid_surface, :icon}}

      not optional_string?(description, 256) ->
        {:error, {:invalid_surface, :description}}

      true ->
        {:ok,
         %{id: id, label: label, path: path, app_id: app_id, icon: icon, description: description}}
    end
  end

  defp normalize_surface(_surface, _app_id), do: {:error, {:invalid_surface, :shape}}

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

  defp optional_string?(nil, _max), do: true
  defp optional_string?(value, max), do: is_binary(value) and byte_size(value) <= max

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
