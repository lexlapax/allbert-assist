defmodule StockSage.Agents.ModelProfile do
  @moduledoc "Resolve v0.25 StockSage native-agent model profiles from Settings Central."

  alias AllbertAssist.Settings
  alias StockSage.Agents

  @spec resolve(atom() | String.t()) :: String.t()
  def resolve(role) do
    spec = Agents.spec!(role)

    spec
    |> per_agent_setting_key()
    |> settings_value()
    |> blank_to_nil()
    |> case do
      nil ->
        role_default(spec) ||
          "stocksage.native_model_profile"
          |> settings_value()
          |> blank_to_nil() ||
          "fast"

      value ->
        value
    end
  end

  defp per_agent_setting_key(%{model_role: nil}), do: nil

  defp per_agent_setting_key(%{model_role: role}) do
    "stocksage.native_model_profile_#{role}"
  end

  defp role_default(%{default_model_profile: value}) when is_binary(value) do
    blank_to_nil(value)
  end

  defp role_default(_spec), do: nil

  defp settings_value(nil), do: nil

  defp settings_value(key) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: to_string(value)
end
