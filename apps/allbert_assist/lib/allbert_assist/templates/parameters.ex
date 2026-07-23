defmodule AllbertAssist.Templates.Parameters do
  @moduledoc """
  Parameter validation and common normalization for v0.38 templates.

  This module never creates atoms from operator/developer input. Derived ids are
  strings that later reviewed code may compare or render as inert source.
  """

  alias AllbertAssist.Maps

  @name_regex ~r/^[a-z][a-z0-9_]*$/

  @doc "Validate a pattern parameter schema against raw params."
  @spec validate([map()], map()) :: {:ok, map()} | {:error, term()}
  def validate(schema, params) when is_list(schema) and is_map(params) do
    with {:ok, entries} <- normalize_schema(schema),
         :ok <- reject_unknown_params(entries, params) do
      validate_entries(entries, params)
    end
  end

  def validate(_schema, _params), do: {:error, :invalid_parameter_input}

  defp validate_entries(entries, params) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case validate_entry(entry, params) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, entry.name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_entry(entry, params) do
    with {:ok, value} <- value_for(entry, params) do
      validate_value(entry, value)
    end
  end

  @doc "Add common string identifiers derived from a validated `name` value."
  @spec derive_common(map()) :: {:ok, map()} | {:error, term()}
  def derive_common(params) when is_map(params) do
    base_name = Map.get(params, "name") || Map.get(params, "slug")

    with {:ok, slug} <- slug(base_name) do
      display_name = display_name(Map.get(params, "display_name") || base_name)
      module_basename = module_basename(slug)

      {:ok,
       params
       |> Map.put_new("slug", slug)
       |> Map.put_new("app_id", slug)
       |> Map.put_new("destination_id", "app:#{slug}")
       |> Map.put_new("schedule_id", slug)
       |> Map.put_new("display_name", display_name)
       |> Map.put_new("module_basename", module_basename)
       |> Map.put_new("module_namespace", module_basename)
       |> put_literal("display_name_literal", display_name)
       |> put_literal("description_literal", Map.get(params, "description", ""))
       |> put_literal("slug_literal", slug)}
    end
  end

  def derive_common(_params), do: {:error, :invalid_parameter_input}

  @doc "Normalize an arbitrary operator-facing name into a safe snake-case slug."
  @spec slug(term()) :: {:ok, String.t()} | {:error, term()}
  def slug(value) when is_binary(value) do
    slug =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    cond do
      slug == "" -> {:error, :missing_name}
      String.length(slug) > 64 -> {:error, {:name_too_long, 64}}
      Regex.match?(@name_regex, slug) -> {:ok, slug}
      true -> {:error, {:invalid_slug, slug}}
    end
  end

  def slug(_value), do: {:error, :missing_name}

  @doc "Return a CamelCase module basename from a safe slug."
  @spec module_basename(String.t()) :: String.t()
  def module_basename(slug) when is_binary(slug) do
    slug
    |> String.split("_", trim: true)
    |> Enum.map_join("", &capitalize_segment/1)
  end

  defp normalize_schema(schema) do
    Enum.reduce_while(schema, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_unknown_params(entries, params) do
    allowed = entries |> Enum.map(& &1.name) |> MapSet.new()

    unknown =
      params
      |> Map.keys()
      |> Enum.map(&normalize_name/1)
      |> Enum.reject(&(is_binary(&1) and MapSet.member?(allowed, &1)))

    case unknown do
      [] -> :ok
      values -> {:error, {:unknown_template_parameters, values}}
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    name = entry |> field(:name) |> normalize_name()
    type = field(entry, :type)

    cond do
      not is_binary(name) or name == "" ->
        {:error, {:invalid_parameter_name, field(entry, :name)}}

      invalid_type?(type) ->
        {:error, {:invalid_parameter_type, name, type}}

      true ->
        {:ok, Map.merge(entry, %{name: name, type: type})}
    end
  end

  defp normalize_entry(entry) when is_list(entry), do: entry |> Map.new() |> normalize_entry()
  defp normalize_entry(entry), do: {:error, {:invalid_parameter_schema_entry, entry}}

  defp invalid_type?(:string), do: false
  defp invalid_type?(:boolean), do: false
  defp invalid_type?(:enum), do: false
  defp invalid_type?({:list, :string}), do: false
  defp invalid_type?(_type), do: true

  defp value_for(entry, params) do
    case fetch_param(params, entry.name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        cond do
          Map.has_key?(entry, :default) -> {:ok, Map.fetch!(entry, :default)}
          Map.get(entry, :required, false) -> {:error, {:missing_required_parameter, entry.name}}
          true -> {:ok, nil}
        end
    end
  end

  defp validate_value(_entry, nil), do: {:ok, nil}

  defp validate_value(%{type: :string} = entry, value) when is_binary(value) do
    value = String.trim(value)

    with :ok <- validate_length(entry, value),
         :ok <- validate_pattern(entry, value) do
      {:ok, value}
    end
  end

  defp validate_value(%{type: :string, name: name}, value),
    do: {:error, {:invalid_string_parameter, name, value}}

  defp validate_value(%{type: :boolean}, value) when is_boolean(value), do: {:ok, value}
  defp validate_value(%{type: :boolean}, "true"), do: {:ok, true}
  defp validate_value(%{type: :boolean}, "false"), do: {:ok, false}

  defp validate_value(%{type: :boolean, name: name}, value),
    do: {:error, {:invalid_boolean_parameter, name, value}}

  defp validate_value(%{type: :enum, name: name} = entry, value) when is_binary(value) do
    allowed = Map.get(entry, :allowed_values, [])

    if value in allowed do
      {:ok, value}
    else
      {:error, {:invalid_enum_parameter, name, value, allowed}}
    end
  end

  defp validate_value(%{type: {:list, :string}, name: name}, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, Enum.map(values, &String.trim/1)}
    else
      {:error, {:invalid_string_list_parameter, name}}
    end
  end

  defp validate_value(%{type: {:list, :string}, name: name}, value),
    do: {:error, {:invalid_string_list_parameter, name, value}}

  defp validate_length(entry, value) do
    min = Map.get(entry, :min_length, 0)
    max = Map.get(entry, :max_length, 256)
    length = String.length(value)

    cond do
      length < min -> {:error, {:parameter_too_short, entry.name, min}}
      length > max -> {:error, {:parameter_too_long, entry.name, max}}
      true -> :ok
    end
  end

  defp validate_pattern(%{pattern: %Regex{} = regex, name: name}, value) do
    if Regex.match?(regex, value), do: :ok, else: {:error, {:parameter_pattern_mismatch, name}}
  end

  defp validate_pattern(_entry, _value), do: :ok

  defp fetch_param(params, name) do
    if Map.has_key?(params, name) do
      {:ok, Map.fetch!(params, name)}
    else
      atom_name = String.to_existing_atom(name)

      if Map.has_key?(params, atom_name), do: {:ok, Map.fetch!(params, atom_name)}, else: :error
    end
  rescue
    ArgumentError -> :error
  end

  defp field(map, key), do: Maps.field(map, key)
  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(_name), do: nil

  defp put_literal(params, key, value) do
    Map.put_new(params, key, inspect(to_string(value)))
  end

  defp display_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> "Untitled"
      text -> text
    end
  end

  defp display_name(_value), do: "Untitled"

  defp capitalize_segment(<<first::binary-size(1), rest::binary>>) do
    String.upcase(first) <> rest
  end

  defp capitalize_segment(""), do: ""
end
