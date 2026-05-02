defmodule AllbertAssist.Settings.YamlCodec do
  @moduledoc false

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
    Ymlr.document!(map, sort_maps: true)
  end

  defp yaml_error_message(%{message: message}), do: message
end
