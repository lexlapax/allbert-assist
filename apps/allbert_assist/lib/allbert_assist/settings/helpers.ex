defmodule AllbertAssist.Settings.Helpers do
  @moduledoc """
  Helpers for Settings Central DTO rows.
  """

  @spec setting_bool([map()], String.t(), boolean()) :: boolean()
  def setting_bool(settings, key, default) when is_list(settings) do
    settings
    |> Enum.find(&(&1.key == key))
    |> case do
      %{value: value} when is_boolean(value) -> value
      _setting -> default
    end
  end

  def setting_bool(_settings, _key, default), do: default
end
