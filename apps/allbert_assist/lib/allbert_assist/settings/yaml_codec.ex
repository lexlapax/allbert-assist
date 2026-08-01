defmodule AllbertAssist.Settings.YamlCodec.QuotedScalar do
  @moduledoc false

  @enforce_keys [:value]
  defstruct [:value]
end

defimpl Ymlr.Encoder, for: AllbertAssist.Settings.YamlCodec.QuotedScalar do
  def encode(%{value: value}, _indent_level, _opts), do: inspect(value)
end

defmodule AllbertAssist.Settings.YamlCodec do
  @moduledoc false

  alias AllbertAssist.Settings.YamlCodec.QuotedScalar

  def read_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:settings_parse_failed, {:expected_map, other}}}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, %{}}
      {:error, reason} -> {:error, {:settings_parse_failed, yaml_error_message(reason)}}
    end
  end

  def read_string(string) when is_binary(string) do
    case YamlElixir.read_from_string(string) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:settings_parse_failed, {:expected_map, other}}}
      {:error, reason} -> {:error, {:settings_parse_failed, yaml_error_message(reason)}}
    end
  end

  def encode!(map) when is_map(map) do
    map
    |> protect_scalar_values()
    |> Ymlr.document!(sort_maps: true)
  end

  defp protect_scalar_values(value) when is_binary(value) do
    if :binary.match(value, "\r") == :nomatch,
      do: value,
      else: %QuotedScalar{value: value}
  end

  defp protect_scalar_values(%_{} = struct), do: struct

  defp protect_scalar_values(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, protect_scalar_values(value)} end)
  end

  defp protect_scalar_values(list) when is_list(list),
    do: Enum.map(list, &protect_scalar_values/1)

  defp protect_scalar_values(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&protect_scalar_values/1)
    |> List.to_tuple()
  end

  defp protect_scalar_values(value), do: value

  defp yaml_error_message(%{message: message}), do: message
end
