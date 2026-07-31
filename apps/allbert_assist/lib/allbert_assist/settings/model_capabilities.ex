defmodule AllbertAssist.Settings.ModelCapabilities do
  @moduledoc """
  Canonical capability policy for model selection boundaries.

  Profiles with an explicit non-empty capability list are authoritative. Older
  profiles created before capability metadata remain text-generation profiles
  when they still name a model; that is the only inferred capability.
  """

  @doc "Whether a profile explicitly declares a capability."
  @spec declares?(map(), atom() | String.t()) :: boolean()
  def declares?(profile, capability) when is_map(profile) do
    capability = to_string(capability)
    capabilities = field(profile, :capabilities)

    is_list(capabilities) and capability in Enum.map(capabilities, &to_string/1)
  end

  def declares?(_profile, _capability), do: false

  @doc "Runtime compatibility predicate, including the pre-capability text-profile shape."
  @spec runtime_supports?(map(), atom() | String.t()) :: boolean()
  def runtime_supports?(profile, capability) when is_map(profile) do
    capability = to_string(capability)
    capabilities = field(profile, :capabilities)

    cond do
      declares?(profile, capability) ->
        true

      capability == "text_generation" and capabilities in [nil, []] ->
        profile |> field(:model) |> valid_model?()

      true ->
        false
    end
  end

  def runtime_supports?(_profile, _capability), do: false

  @spec declares_text_generation?(map()) :: boolean()
  def declares_text_generation?(profile), do: declares?(profile, "text_generation")

  @spec runtime_text_generation?(map()) :: boolean()
  def runtime_text_generation?(profile), do: runtime_supports?(profile, "text_generation")

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp valid_model?(model), do: is_binary(model) and String.trim(model) != ""
end
