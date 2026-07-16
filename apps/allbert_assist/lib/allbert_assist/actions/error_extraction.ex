defmodule AllbertAssist.Actions.ErrorExtraction do
  @moduledoc """
  Extracts a compact error reason from action responses.
  """

  alias AllbertAssist.Maps

  @metadata_keys [
    :settings_metadata,
    :confirmation_metadata,
    :resource_metadata,
    :marketplace_metadata,
    :security_metadata,
    :tool_metadata,
    :session_metadata
  ]

  @spec from_response(map() | term()) :: term()
  def from_response(%{error: error}) when not is_nil(error), do: error

  def from_response(%{actions: actions, message: message}) when is_list(actions) do
    Enum.find_value(actions, &action_error/1) || message
  end

  def from_response(%{message: message}), do: message
  def from_response(response), do: response

  defp action_error(action) when is_map(action) do
    direct_error(action) ||
      Enum.find_value(@metadata_keys, fn key ->
        action
        |> field(key)
        |> direct_error()
      end)
  end

  defp action_error(_action), do: nil

  defp direct_error(map) when is_map(map), do: field(map, :error)
  defp direct_error(_value), do: nil

  defp field(map, key), do: Maps.field(map, key)
end
