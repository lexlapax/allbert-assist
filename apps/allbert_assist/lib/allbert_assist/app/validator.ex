defmodule AllbertAssist.App.Validator do
  @moduledoc false

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry

  @required_exports [
    app_id: 0,
    display_name: 0,
    version: 0,
    validate: 1,
    child_spec: 1,
    agents: 0,
    actions: 0,
    signals: 0,
    skill_paths: 0,
    settings_schema: 0,
    surfaces: 0
  ]

  @app_id_regex ~r/^[a-z][a-z0-9_]*$/
  @reserved_nil_aliases [:none, :general]
  @reserved_app_owners %{
    allbert: [AllbertAssist.App.CoreApp],
    stocksage: [AllbertAssist.App.StockSageStub, StockSage.App]
  }

  @known_setting_types [
    :string,
    :string_or_empty,
    :email_or_empty,
    :timezone,
    :enum,
    :boolean,
    :string_list,
    :http_methods,
    :external_service_profiles,
    :command_profiles,
    :interpreter_profiles,
    :package_manager_profiles,
    :resource_grants,
    :url_or_nil,
    :secret_ref_or_nil,
    :channel_secret_ref,
    :channel_identity_map,
    :provider_ref,
    :profile_ref,
    :temperature,
    :positive_integer,
    :bounded_integer,
    :non_negative_integer,
    :timeout_ms
  ]

  @type result :: {:ok, map()} | {:error, {atom(), term()}, [map()]}

  @spec validate(module(), keyword() | map()) :: result()
  def validate(module, opts \\ []) do
    with {:ok, module} <- validate_module(module),
         {:ok, app_id} <- validate_app_id(module),
         {:ok, display_name} <- validate_string(module, :display_name, 64),
         {:ok, version} <- validate_string(module, :version, 32),
         :ok <- run_app_validation(module, opts),
         {:ok, agents} <- validate_agents(module),
         {:ok, actions} <- validate_actions(module),
         {:ok, signals} <- validate_signals(module),
         {:ok, skill_paths} <- validate_skill_paths(module),
         {:ok, settings_schema} <- validate_settings_schema(module, app_id),
         {:ok, surface_provider} <- validate_surface_provider(module, app_id),
         {:ok, surfaces} <- validate_surfaces(module, app_id, surface_provider.provider?) do
      {:ok,
       %{
         app_id: app_id,
         module: module,
         display_name: display_name,
         version: version,
         agents: agents,
         actions: actions,
         signals: signals,
         skill_paths: skill_paths,
         settings_schema: settings_schema,
         surfaces: surfaces,
         surface_provider: surface_provider.module,
         provider_surfaces: surface_provider.surfaces,
         surface_catalog: surface_provider.catalog
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

  defp validate_agents(module) do
    case module.agents() do
      agents when is_list(agents) ->
        validate_agent_modules(agents, module, [])

      _other ->
        {:error, {:invalid_agents, module}}
    end
  end

  defp validate_agent_modules([], _module, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_agent_modules([agent | rest], module, acc) do
    if is_atom(agent) and Code.ensure_loaded?(agent) do
      validate_agent_modules(rest, module, [agent | acc])
    else
      {:error, {:invalid_agents, module}}
    end
  end

  defp validate_signals(module) do
    case module.signals() do
      %{emits: emits, subscribes: subscribes} = signals ->
        with :ok <- validate_signal_topics(emits),
             :ok <- validate_signal_topics(subscribes) do
          {:ok, %{emits: signals.emits, subscribes: signals.subscribes}}
        else
          {:error, reason} -> {:error, {:invalid_signals, reason}}
        end

      _other ->
        {:error, {:invalid_signals, module}}
    end
  end

  defp validate_signal_topics(topics) when is_list(topics) do
    if Enum.all?(topics, &valid_signal_topic?/1), do: :ok, else: {:error, :topic}
  end

  defp validate_signal_topics(_topics), do: {:error, :topic_list}

  defp valid_signal_topic?(topic) when is_binary(topic) do
    byte_size(topic) in 1..128 and
      Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$/, topic)
  end

  defp valid_signal_topic?(_topic), do: false

  defp validate_settings_schema(module, app_id) do
    case module.settings_schema() do
      schema when is_list(schema) ->
        normalize_settings_schema(schema, app_id, [])

      _other ->
        {:error, {:invalid_settings_schema, module}}
    end
  end

  defp normalize_settings_schema([], _app_id, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_settings_schema([entry | rest], app_id, acc) when is_map(entry) do
    key = field(entry, :key)
    type = field(entry, :type)

    cond do
      not is_binary(key) or not String.starts_with?(key, "apps.#{app_id}.") ->
        {:error, {:invalid_settings_schema, :key}}

      type not in @known_setting_types ->
        {:error, {:invalid_settings_schema, :type}}

      not json_safe?(field(entry, :default)) ->
        {:error, {:invalid_settings_schema, :default}}

      true ->
        normalize_settings_schema(rest, app_id, [
          %{
            app_id: app_id,
            key: key,
            type: type,
            default: field(entry, :default),
            description: normalize_optional_string(field(entry, :description)) || "",
            secret?: field(entry, :secret?, false)
          }
          | acc
        ])
    end
  end

  defp normalize_settings_schema(_schema, _app_id, _acc),
    do: {:error, {:invalid_settings_schema, :entry}}

  defp validate_surface_provider(module, app_id) do
    if surface_provider?(module) do
      with {:ok, provider_surfaces} <- validate_provider_surfaces(module, app_id),
           {:ok, catalog} <- validate_provider_catalog(module) do
        {:ok, %{provider?: true, module: module, surfaces: provider_surfaces, catalog: catalog}}
      end
    else
      {:ok, %{provider?: false, module: nil, surfaces: [], catalog: []}}
    end
  end

  defp surface_provider?(module) do
    attributes = module.module_info(:attributes)

    behaviours =
      attributes
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    AllbertAssist.App.SurfaceProvider in behaviours or
      attributes
      |> Keyword.get_values(:allbert_surface_provider)
      |> List.flatten()
      |> Enum.member?(true)
  rescue
    _exception -> false
  end

  defp validate_provider_surfaces(module, app_id) do
    with surfaces when is_list(surfaces) <- module.surfaces(),
         {:ok, validated} <- validate_surface_list(surfaces),
         :ok <- validate_provider_surface_app_ids(validated, app_id),
         :ok <- validate_unique_provider_surface_ids(validated) do
      {:ok, validated}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:invalid_surface_provider, module}}
    end
  end

  defp validate_surface_list(surfaces) do
    Enum.reduce_while(surfaces, {:ok, []}, fn surface, {:ok, acc} ->
      case AllbertAssist.Surface.validate_surface(surface) do
        {:ok, surface} -> {:cont, {:ok, [surface | acc]}}
        {:error, diagnostics} -> {:halt, {:error, {:invalid_surface_provider, diagnostics}}}
      end
    end)
    |> case do
      {:ok, surfaces} -> {:ok, Enum.reverse(surfaces)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_provider_surface_app_ids(surfaces, app_id) do
    if Enum.all?(surfaces, &(&1.app_id == app_id)) do
      :ok
    else
      {:error, {:invalid_surface_provider, :app_id}}
    end
  end

  defp validate_unique_provider_surface_ids(surfaces) do
    duplicates =
      surfaces
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)

    if duplicates == [], do: :ok, else: {:error, {:invalid_surface_provider, :duplicate_id}}
  end

  defp validate_provider_catalog(module) do
    case module.surface_catalog() do
      catalog when is_list(catalog) -> AllbertAssist.Surface.validate_catalog(catalog)
      _other -> {:error, {:invalid_surface_catalog, module}}
    end
  end

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

  defp validate_surfaces(_module, _app_id, true), do: {:ok, []}

  defp validate_surfaces(module, app_id, false) do
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

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> json_safe?(nested)
      {_key, _nested} -> false
    end)
  end

  defp json_safe?(_value), do: false

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

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
