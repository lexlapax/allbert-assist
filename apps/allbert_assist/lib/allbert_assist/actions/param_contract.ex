defmodule AllbertAssist.Actions.ParamContract do
  @moduledoc """
  Allbert-owned strictness wrapper around Jido action param validation.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Runtime.Redactor
  alias Jido.Action.Schema

  @type validation_result :: {:ok, map()} | {:error, term()}

  @doc """
  Normalize schema-known string keys, reject unknown keys, then call Jido validation.
  """
  @spec normalize_and_validate(module(), map()) :: validation_result()
  def normalize_and_validate(action_module, params)
      when is_atom(action_module) and is_map(params) do
    schema = action_schema(action_module)

    with {:ok, normalized_params} <- normalize_schema_known_keys(params, schema),
         :ok <- reject_unknown_keys(action_module, normalized_params, schema),
         {:ok, validation_params, passthrough_params} <-
           prepare_validation_params(action_module, normalized_params, schema),
         {:ok, validated_params} <- validate_with_jido(action_module, validation_params) do
      {:ok, Map.merge(validated_params, passthrough_params)}
    end
  end

  @doc "Return the generated param-contract catalog for currently registered actions."
  @spec catalog() :: [map()]
  def catalog do
    Registry.modules()
    |> Enum.uniq()
    |> Enum.map(&catalog_entry/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Return a redacted, stable reason safe for runner responses and evidence."
  @spec redacted_reason(term()) :: term()
  def redacted_reason(reason), do: Redactor.redact(reason)

  defp normalize_schema_known_keys(params, schema) do
    key_forms = known_key_forms(schema)

    normalized =
      key_forms
      |> Enum.reduce({%{}, params}, fn form, {known_acc, rest} ->
        {value, rest} = pop_known_value(rest, form)

        case value do
          :__allbert_missing__ -> {known_acc, rest}
          _ -> {Map.put(known_acc, target_key(form), value), rest}
        end
      end)
      |> then(fn {known_params, unknown_params} -> Map.merge(unknown_params, known_params) end)

    {:ok, normalized}
  end

  defp pop_known_value(params, %{atom: atom, string: string})
       when is_atom(atom) and not is_nil(atom) do
    {atom_value, rest} = Map.pop(params, atom, :__allbert_missing__)

    case atom_value do
      :__allbert_missing__ ->
        Map.pop(rest, string, :__allbert_missing__)

      _value ->
        {_dropped_string_value, rest} = Map.pop(rest, string, :__allbert_missing__)
        {atom_value, rest}
    end
  end

  defp pop_known_value(params, %{string: string}),
    do: Map.pop(params, string, :__allbert_missing__)

  defp target_key(%{atom: atom}) when is_atom(atom) and not is_nil(atom), do: atom
  defp target_key(%{string: string}), do: string

  defp reject_unknown_keys(action_module, params, schema) do
    allowed = known_target_keys(schema)

    params
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> case do
      [] -> :ok
      keys -> {:error, {:unknown_params, action_module.name(), safe_keys(keys)}}
    end
  end

  defp validate_with_jido(action_module, params) do
    if function_exported?(action_module, :validate_params, 1) do
      case action_module.validate_params(params) do
        {:ok, validated_params} when is_map(validated_params) ->
          {:ok, validated_params}

        {:error, reason} ->
          {:error, {:validation_failed, action_module.name(), redacted_reason(reason)}}

        other ->
          {:error,
           {:invalid_validate_params_result, action_module.name(), redacted_reason(other)}}
      end
    else
      {:error, {:missing_validate_params, action_module.name()}}
    end
  end

  defp prepare_validation_params(action_module, params, schema) when is_list(schema) do
    with :ok <- validate_required_open_maps(action_module, params, schema) do
      prepare_validation_entries(action_module, params, schema)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_validation_params(_action_module, params, _schema), do: {:ok, params, %{}}

  defp prepare_validation_entries(action_module, params, schema) do
    params
    |> Enum.reduce_while({%{}, %{}}, fn {key, value}, acc ->
      reduce_validation_entry(action_module, schema, key, value, acc)
    end)
    |> finalize_validation_entries()
  end

  defp reduce_validation_entry(
         action_module,
         schema,
         key,
         value,
         {validation_acc, passthrough_acc}
       ) do
    case prepare_validation_entry(action_module, schema, key, value) do
      {:validation, prepared_value} ->
        {:cont, {Map.put(validation_acc, key, prepared_value), passthrough_acc}}

      {:validation_with_passthrough, prepared_value} ->
        {:cont,
         {Map.put(validation_acc, key, prepared_value), Map.put(passthrough_acc, key, value)}}

      :drop ->
        {:cont, {validation_acc, passthrough_acc}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp finalize_validation_entries({:error, reason}), do: {:error, reason}

  defp finalize_validation_entries({validation_params, passthrough_params}),
    do: {:ok, validation_params, passthrough_params}

  defp prepare_validation_entry(action_module, schema, key, value) do
    schema_entry = Keyword.get(schema, key, [])

    cond do
      optional_nil?(schema_entry, value) ->
        :drop

      open_map_field?(schema_entry) ->
        case validate_open_map_value(action_module, key, value, schema_entry) do
          :ok -> {:validation_with_passthrough, open_map_placeholder(value, schema_entry)}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:validation, value}
    end
  end

  defp validate_required_open_maps(action_module, params, schema) do
    schema
    |> Enum.filter(fn {_key, opts} ->
      open_map_field?(opts) and Keyword.get(opts, :required, false)
    end)
    |> Enum.find_value(:ok, fn {key, _opts} ->
      if Map.has_key?(params, key) do
        false
      else
        {:error, {:missing_required_param, action_module.name(), safe_key(key)}}
      end
    end)
  end

  defp optional_nil?(schema_entry, nil) do
    schema_entry != [] and not Keyword.get(schema_entry, :required, false)
  end

  defp optional_nil?(_schema_entry, _value), do: false

  defp open_map_field?(schema_entry) when is_list(schema_entry) do
    Keyword.get(schema_entry, :keys) in [nil, []] and
      Keyword.get(schema_entry, :type) in [:map, {:list, :map}]
  end

  defp open_map_field?(_schema_entry), do: false

  defp validate_open_map_value(action_module, key, value, schema_entry) do
    case Keyword.get(schema_entry, :type) do
      :map when is_map(value) ->
        :ok

      {:list, :map} when is_list(value) ->
        if Enum.all?(value, &is_map/1) do
          :ok
        else
          {:error, {:invalid_open_map_param, action_module.name(), safe_key(key)}}
        end

      _type ->
        {:error, {:invalid_open_map_param, action_module.name(), safe_key(key)}}
    end
  end

  defp open_map_placeholder(_value, schema_entry) do
    case Keyword.get(schema_entry, :type) do
      :map -> %{}
      {:list, :map} -> []
    end
  end

  defp catalog_entry(action_module) do
    schema = action_schema(action_module)
    schema_type = Schema.schema_type(schema)

    %{
      name: action_module.name(),
      module: inspect(action_module),
      schema_type: schema_type,
      known_keys: known_key_names(schema),
      disposition: disposition(schema_type)
    }
  end

  defp disposition(:empty), do: :no_params
  defp disposition(:json_schema), do: :json_schema_runtime_unsupported
  defp disposition(:unknown), do: :unsupported_schema
  defp disposition(_schema_type), do: :runtime_validated_closed

  defp action_schema(action_module) do
    if function_exported?(action_module, :schema, 0), do: action_module.schema(), else: []
  end

  defp known_target_keys(schema) do
    schema
    |> known_key_forms()
    |> Enum.map(&target_key/1)
    |> MapSet.new()
  end

  defp known_key_names(schema) do
    schema
    |> known_key_forms()
    |> Enum.map(& &1.string)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp known_key_forms(schema) do
    case Schema.schema_type(schema) do
      :json_schema ->
        Schema.json_schema_known_key_forms(schema)

      _other ->
        schema
        |> Schema.known_keys()
        |> Enum.map(&%{atom: &1, string: Atom.to_string(&1)})
    end
  end

  defp safe_keys(keys) do
    keys
    |> Enum.map(&safe_key/1)
    |> Enum.sort()
  end

  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key), do: inspect(key)
end
