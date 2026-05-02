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

  defp yaml_error_message(%_{} = exception) do
    if is_exception(exception) do
      Exception.message(exception)
    else
      inspect(exception)
    end
  end

  defp yaml_error_message(%{} = error) do
    case Map.fetch(error, :message) do
      {:ok, message} when is_binary(message) -> message
      _other -> inspect(error)
    end
  end

  defp yaml_error_message(message) when is_binary(message), do: message
  defp yaml_error_message(reason), do: inspect(reason)
end
