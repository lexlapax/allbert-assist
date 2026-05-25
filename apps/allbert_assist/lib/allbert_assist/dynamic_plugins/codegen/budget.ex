defmodule AllbertAssist.DynamicPlugins.Codegen.Budget do
  @moduledoc """
  Provider-call and usage budget checks for v0.37 draft generation.
  """

  alias AllbertAssist.Settings

  @doc "Validate a generation request against Settings Central budgets."
  def check(requested) when is_map(requested) do
    max_calls = setting("dynamic_codegen.max_provider_calls_per_gap", 8)
    max_usage = setting("dynamic_codegen.max_provider_usage_units_per_gap", 20_000)
    requested_calls = integer_field(requested, :provider_calls_requested, 0)
    requested_usage = integer_field(requested, :provider_usage_units_requested, 0)

    cond do
      requested_calls > max_calls ->
        {:error,
         {:dynamic_codegen_budget_exhausted,
          %{"budget" => "provider_calls", "requested" => requested_calls, "limit" => max_calls}}}

      is_integer(max_usage) and requested_usage > max_usage ->
        {:error,
         {:dynamic_codegen_budget_exhausted,
          %{
            "budget" => "provider_usage_units",
            "requested" => requested_usage,
            "limit" => max_usage
          }}}

      true ->
        {:ok,
         %{
           "provider_calls_budget" => max_calls,
           "provider_calls_requested" => requested_calls,
           "provider_calls_used" => 0,
           "provider_usage_units_budget" => max_usage,
           "provider_usage_units_requested" => requested_usage,
           "provider_usage_units_used" => 0
         }}
    end
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp integer_field(map, key, default) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    cond do
      is_integer(value) and value >= 0 ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _other -> default
        end

      true ->
        default
    end
  end
end
