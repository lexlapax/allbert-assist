defmodule AllbertAssist.Intent.Router.ScoringProfile do
  @moduledoc """
  Settings Central backed routing score knobs.

  These values are tuning inputs only. They influence ranking/shortlisting but do
  not make any action routable, grant permission, or bypass confirmation.
  """

  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Store

  @prefilter_defaults %{
    complete_required_slots_boost: 0.35,
    missing_required_slots_penalty: 0.25,
    descriptor_text_match_boost: 0.35,
    descriptor_text_match_unit_boost: 0.04,
    descriptor_text_match_cap: 0.25
  }

  @ranker_defaults %{
    complete_required_slots_boost: 0.35,
    descriptor_text_match_boost: 0.45,
    descriptor_text_match_unit_boost: 0.05,
    descriptor_text_match_cap: 0.25
  }

  @prefilter_keys %{
    complete_required_slots_boost:
      "intent.router_scoring.prefilter.complete_required_slots_boost",
    missing_required_slots_penalty:
      "intent.router_scoring.prefilter.missing_required_slots_penalty",
    descriptor_text_match_boost: "intent.router_scoring.prefilter.descriptor_text_match_boost",
    descriptor_text_match_unit_boost:
      "intent.router_scoring.prefilter.descriptor_text_match_unit_boost",
    descriptor_text_match_cap: "intent.router_scoring.prefilter.descriptor_text_match_cap"
  }

  @ranker_keys %{
    complete_required_slots_boost: "intent.router_scoring.ranker.complete_required_slots_boost",
    descriptor_text_match_boost: "intent.router_scoring.ranker.descriptor_text_match_boost",
    descriptor_text_match_unit_boost:
      "intent.router_scoring.ranker.descriptor_text_match_unit_boost",
    descriptor_text_match_cap: "intent.router_scoring.ranker.descriptor_text_match_cap"
  }

  @spec prefilter() :: map()
  def prefilter, do: profile(@prefilter_keys, @prefilter_defaults)

  @spec ranker() :: map()
  def ranker, do: profile(@ranker_keys, @ranker_defaults)

  defp profile(keys, defaults) do
    Map.new(defaults, fn {name, default} ->
      {name, setting_float(Map.fetch!(keys, name), default)}
    end)
  end

  defp setting_float(key, default) do
    case setting_value(key) do
      {:ok, value} when is_number(value) -> value * 1.0
      _other -> default
    end
  end

  defp setting_value(key) do
    with {:ok, user_settings} <- Store.read_user_settings(),
         value when not is_nil(value) <- Schema.get_dotted(user_settings, key) do
      {:ok, value}
    else
      _other -> {:ok, Schema.get_dotted(Schema.core_defaults(), key)}
    end
  end
end
