defmodule AllbertAssist.Settings.FragmentOwner do
  @moduledoc """
  Compiled owner contract for one complete Settings Central fragment.

  Pack callbacks expose owner module references. Settings Central resolves the
  trusted compiled modules, validates their application ownership, and remains
  the sole composition and runtime authority.
  """

  alias AllbertAssist.Settings.Fragment

  @callback fragment() :: Fragment.t()
  @callback composition_defaults() :: map()
  @callback dynamic_default_keys() :: [String.t()]
  @callback safe_write_rows() :: [{pos_integer(), String.t()}]
  @callback supplemental_safe_write_keys() :: [String.t()]

  @optional_callbacks composition_defaults: 0,
                      dynamic_default_keys: 0,
                      safe_write_rows: 0,
                      supplemental_safe_write_keys: 0

  @spec owner_module?(term()) :: boolean()
  def owner_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :fragment, 0) and
      __MODULE__ in behaviours(module)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  def owner_module?(_module), do: false

  @doc "Return the independent compiled fragment-owner census for one OTP application."
  @spec compiled_owner_modules(atom()) :: {:ok, [module()]} | {:error, term()}
  def compiled_owner_modules(application) when is_atom(application) do
    case Application.spec(application, :modules) do
      modules when is_list(modules) ->
        {:ok, modules |> Enum.filter(&owner_module?/1) |> Enum.sort()}

      _other ->
        {:error, {:settings_fragment_application_unavailable, application}}
    end
  end

  def compiled_owner_modules(application),
    do: {:error, {:invalid_settings_fragment_application, application}}

  @doc "Resolve and validate one Pack's declared fragment-owner module references."
  @spec resolve_pack(String.t(), atom(), [module()]) ::
          {:ok, [map()]} | {:error, term()}
  def resolve_pack(pack_id, application, modules)
      when is_binary(pack_id) and pack_id != "" and is_atom(application) and is_list(modules) do
    declared = Enum.sort(modules)

    with :ok <- unique_modules(declared),
         {:ok, compiled} <- compiled_owner_modules(application),
         :ok <- exact_census(pack_id, declared, compiled),
         {:ok, contributions} <- resolve_modules(pack_id, application, declared),
         :ok <- unique_fragment_ids(contributions),
         :ok <- validate_safe_write_rows(contributions) do
      {:ok, Enum.sort_by(contributions, & &1.fragment.id)}
    end
  end

  def resolve_pack(pack_id, application, modules),
    do: {:error, {:invalid_settings_fragment_declaration, pack_id, application, modules}}

  @doc "Resolve one Pack's fragment modules or raise before Settings consumers start."
  @spec resolve_pack!(String.t(), atom(), [module()]) :: [map()]
  def resolve_pack!(pack_id, application, modules) do
    case resolve_pack(pack_id, application, modules) do
      {:ok, contributions} ->
        contributions

      {:error, reason} ->
        raise ArgumentError, "invalid settings fragment owners: #{inspect(reason)}"
    end
  end

  @doc "Return the fragments from one validated Pack owner declaration."
  @spec fragments!(String.t(), atom(), [module()]) :: [Fragment.t()]
  def fragments!(pack_id, application, modules) do
    pack_id
    |> resolve_pack!(application, modules)
    |> Enum.map(& &1.fragment)
  end

  @doc false
  @spec validate_owner(String.t(), atom(), module()) :: {:ok, map()} | {:error, term()}
  def validate_owner(pack_id, application, module)
      when is_binary(pack_id) and is_atom(application) and is_atom(module) do
    case resolve_modules(pack_id, application, [module]) do
      {:ok, [contribution]} -> {:ok, contribution}
      {:error, _reason} = error -> error
    end
  end

  def validate_owner(pack_id, application, module),
    do: {:error, {:invalid_settings_fragment_owner, pack_id, application, module}}

  @doc false
  def schema!(pack_id, application, modules) do
    pack_id
    |> fragments!(application, modules)
    |> Enum.reduce(%{}, fn fragment, schema -> merge_schema!(schema, fragment.schema) end)
  end

  @doc false
  def defaults!(pack_id, application, modules) do
    pack_id
    |> resolve_pack!(application, modules)
    |> Enum.reduce(%{}, fn contribution, defaults ->
      deep_merge(defaults, contribution.defaults)
    end)
  end

  @doc false
  def safe_write_keys!(pack_id, application, modules) do
    pack_id
    |> resolve_pack!(application, modules)
    |> Enum.flat_map(& &1.safe_write_rows)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp resolve_modules(pack_id, application, modules) do
    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, contributions} ->
      if owner_module?(module) do
        case module.fragment() do
          %Fragment{} = fragment ->
            with {:ok, defaults} <- composition_defaults(module, fragment),
                 {:ok, dynamic_default_rows} <-
                   validate_defaults_contract(module, fragment, defaults),
                 {:ok, safe_write_rows, supplemental_safe_write_keys} <-
                   safe_write_rows(module, fragment) do
              contribution = %{
                pack_id: pack_id,
                application: application,
                owner_module: module,
                fragment: fragment,
                defaults: defaults,
                dynamic_default_rows: dynamic_default_rows,
                safe_write_rows: safe_write_rows,
                supplemental_safe_write_keys: supplemental_safe_write_keys
              }

              {:cont, {:ok, [contribution | contributions]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          value ->
            {:halt, {:error, {:invalid_settings_fragment, module, value}}}
        end
      else
        {:halt, {:error, {:invalid_settings_fragment_owner, module}}}
      end
    end)
    |> case do
      {:ok, contributions} -> {:ok, Enum.reverse(contributions)}
      error -> error
    end
  rescue
    exception -> {:error, {:settings_fragment_owner_raised, exception.__struct__}}
  catch
    kind, reason -> {:error, {:settings_fragment_owner_caught, kind, reason}}
  end

  defp merge_schema!(left, right) do
    case Enum.find(Map.keys(right), &Map.has_key?(left, &1)) do
      nil -> Map.merge(left, right)
      key -> raise ArgumentError, "duplicate settings key: #{key}"
    end
  end

  defp unique_modules(modules) do
    if Enum.uniq(modules) == modules,
      do: :ok,
      else: {:error, {:duplicate_settings_fragment_owner_module, modules}}
  end

  defp composition_defaults(module, fragment) do
    if function_exported?(module, :composition_defaults, 0) do
      case module.composition_defaults() do
        defaults when is_map(defaults) -> {:ok, defaults}
        value -> {:error, {:invalid_settings_fragment_defaults, module, value}}
      end
    else
      {:ok, fragment.defaults}
    end
  end

  defp validate_defaults_contract(module, fragment, defaults) do
    with :ok <- validate_schema_contract(module, fragment, defaults),
         {:ok, declarations} <- dynamic_default_keys(module),
         {:ok, rows} <- validate_dynamic_defaults(module, fragment, defaults, declarations) do
      {:ok, rows}
    end
  end

  defp validate_schema_contract(module, fragment, defaults) do
    Enum.reduce_while(fragment.schema, :ok, fn {key, entry}, :ok ->
      cond do
        not is_binary(key) or key == "" or not is_map(entry) ->
          {:halt,
           {:error, {:invalid_settings_fragment_schema_entry, module, key, :invalid_entry}}}

        not Map.has_key?(entry, :type) ->
          {:halt, {:error, {:invalid_settings_fragment_schema_entry, module, key, :missing_type}}}

        not is_atom(Map.get(entry, :type)) ->
          {:halt, {:error, {:invalid_settings_fragment_schema_entry, module, key, :invalid_type}}}

        not Map.has_key?(entry, :default) ->
          {:halt,
           {:error, {:invalid_settings_fragment_schema_entry, module, key, :missing_default}}}

        not Map.has_key?(entry, :writable?) ->
          {:halt,
           {:error, {:invalid_settings_fragment_schema_entry, module, key, :missing_writable}}}

        not is_boolean(Map.get(entry, :writable?)) ->
          {:halt,
           {:error, {:invalid_settings_fragment_schema_entry, module, key, :invalid_writable}}}

        not Map.has_key?(entry, :sensitive?) ->
          {:halt,
           {:error, {:invalid_settings_fragment_schema_entry, module, key, :missing_sensitive}}}

        not is_boolean(Map.get(entry, :sensitive?)) ->
          {:halt,
           {:error, {:invalid_settings_fragment_schema_entry, module, key, :invalid_sensitive}}}

        fetch_dotted(fragment.defaults, key) != {:ok, Map.fetch!(entry, :default)} ->
          {:halt, {:error, {:settings_fragment_default_mismatch, module, key}}}

        fetch_dotted(defaults, key) != {:ok, Map.fetch!(entry, :default)} ->
          {:halt, {:error, {:settings_fragment_composition_default_mismatch, module, key}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp dynamic_default_keys(module) do
    declarations =
      if function_exported?(module, :dynamic_default_keys, 0),
        do: module.dynamic_default_keys(),
        else: []

    cond do
      not is_list(declarations) or
          not Enum.all?(declarations, &valid_dotted_declaration?/1) ->
        {:error, {:invalid_settings_dynamic_default_keys, module, declarations}}

      Enum.uniq(declarations) != declarations ->
        {:error, {:duplicate_settings_dynamic_default_keys, module, declarations}}

      true ->
        {:ok, declarations}
    end
  rescue
    _exception -> {:error, {:invalid_settings_dynamic_default_keys, module}}
  end

  defp validate_dynamic_defaults(module, fragment, defaults, declarations) do
    schema_keys = Map.keys(fragment.schema)

    extras =
      defaults
      |> default_keys([], MapSet.new(schema_keys), declarations)
      |> Enum.reject(&(&1 in schema_keys))
      |> Enum.sort()

    Enum.reduce_while(extras, {:ok, []}, fn key, {:ok, rows} ->
      case Enum.filter(declarations, &dotted_declaration_matches?(&1, key)) do
        [declaration] ->
          {:cont, {:ok, [{key, declaration} | rows]}}

        [] ->
          {:halt,
           {:error,
            {:undeclared_settings_dynamic_defaults, module, undeclared(extras, declarations)}}}

        matches ->
          {:halt,
           {:error, {:ambiguous_settings_dynamic_default, module, key, Enum.sort(matches)}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp undeclared(keys, declarations) do
    Enum.reject(keys, fn key ->
      Enum.any?(declarations, &dotted_declaration_matches?(&1, key))
    end)
  end

  defp default_keys(value, prefix, schema_keys, declarations) when is_map(value) do
    key = Enum.join(prefix, ".")

    declared_boundary? =
      prefix != [] and Enum.any?(declarations, &dotted_declaration_matches?(&1, key))

    if prefix != [] and (MapSet.member?(schema_keys, key) or declared_boundary?) do
      [key]
    else
      Enum.flat_map(value, fn {segment, nested} ->
        default_keys(nested, prefix ++ [to_string(segment)], schema_keys, declarations)
      end)
    end
  end

  defp default_keys(_value, prefix, _schema_keys, _declarations), do: [Enum.join(prefix, ".")]

  defp valid_dotted_declaration?(declaration) when is_binary(declaration) do
    declaration != "" and
      declaration
      |> String.split(".")
      |> Enum.all?(&(&1 != ""))
  end

  defp valid_dotted_declaration?(_declaration), do: false

  defp dotted_declaration_matches?(declaration, key) do
    declaration_segments = String.split(declaration, ".")
    key_segments = String.split(key, ".")

    length(declaration_segments) == length(key_segments) and
      Enum.zip(declaration_segments, key_segments)
      |> Enum.all?(fn {declared, concrete} -> declared == "*" or declared == concrete end)
  end

  defp fetch_dotted(settings, key) do
    key
    |> String.split(".", trim: true)
    |> Enum.reduce_while({:ok, settings}, fn segment, {:ok, value} ->
      case value do
        %{^segment => nested} -> {:cont, {:ok, nested}}
        _other -> {:halt, :error}
      end
    end)
  end

  defp safe_write_rows(module, fragment) do
    if function_exported?(module, :safe_write_rows, 0) do
      with {:ok, supplemental} <- supplemental_safe_write_keys(module) do
        case module.safe_write_rows() do
          rows when is_list(rows) ->
            validate_owner_safe_write_rows(module, fragment, rows, supplemental)

          value ->
            {:error, {:invalid_settings_safe_write_rows, module, value}}
        end
      end
    else
      {:error, {:missing_settings_safe_write_rows, module, fragment.id}}
    end
  end

  defp supplemental_safe_write_keys(module) do
    keys =
      if function_exported?(module, :supplemental_safe_write_keys, 0),
        do: module.supplemental_safe_write_keys(),
        else: []

    if is_list(keys) and Enum.all?(keys, &valid_dotted_declaration?/1) and
         Enum.uniq(keys) == keys,
       do: {:ok, keys},
       else: {:error, {:invalid_settings_supplemental_safe_write_keys, module, keys}}
  rescue
    _exception -> {:error, {:invalid_settings_supplemental_safe_write_keys, module}}
  end

  defp validate_owner_safe_write_rows(module, fragment, rows, supplemental) do
    expected = Enum.sort(fragment.safe_write_keys ++ supplemental)
    actual = rows |> Enum.map(fn {_index, key} -> key end) |> Enum.sort()

    if expected == actual do
      {:ok, rows, supplemental}
    else
      {:error,
       {:settings_safe_write_key_mismatch, module,
        %{missing: expected -- actual, unexpected: actual -- expected}}}
    end
  end

  defp exact_census(_pack_id, declared, declared), do: :ok

  defp exact_census(pack_id, declared, compiled) do
    {:error,
     {:settings_fragment_owner_census_mismatch,
      %{
        pack_id: pack_id,
        missing: compiled -- declared,
        unexpected: declared -- compiled
      }}}
  end

  defp unique_fragment_ids(contributions) do
    ids = Enum.map(contributions, & &1.fragment.id)

    if Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, {:duplicate_settings_fragment_id, ids}}
  end

  defp validate_safe_write_rows(contributions) do
    rows = Enum.flat_map(contributions, & &1.safe_write_rows)

    malformed =
      Enum.reject(rows, fn
        {index, key} when is_integer(index) and index > 0 and is_binary(key) -> true
        _row -> false
      end)

    indexes = Enum.map(rows, &elem(&1, 0))

    cond do
      malformed != [] ->
        {:error, {:invalid_settings_safe_write_rows, malformed}}

      Enum.uniq(indexes) != indexes ->
        {:error, {:duplicate_settings_safe_write_index, indexes}}

      true ->
        :ok
    end
  end

  defp behaviours(module) do
    module
    |> apply(:module_info, [:attributes])
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
