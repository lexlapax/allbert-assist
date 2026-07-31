defmodule AllbertAssist.Settings.DirectAnswerSelection do
  @moduledoc """
  Purpose-owned DirectAnswer profile selection through Settings Central.

  This helper preserves the operator-authored fallback tail, validates the
  selected profile against the runtime text-generation compatibility contract,
  enables only that profile's provider, and reconciles the bounded disclosure
  route set. It does not alter the global primary model.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelCapabilities
  alias AllbertAssist.Settings.Schema

  @spec select(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def select(profile, context \\ %{})

  def select(profile, context) when is_binary(profile) and is_map(context) do
    with {:ok, model_profile} <- Settings.resolve_model_profile(profile),
         :ok <- validate_text_profile(model_profile),
         {:ok, chain} <- chain_with_head(profile),
         {:ok, provider_setting} <-
           Settings.put("providers.#{model_profile.provider}.enabled", true, context),
         {:ok, task_setting} <-
           Settings.put("model_preferences.tasks.direct_answer", chain, context),
         :ok <- Disclosure.reconcile_current_direct_answer_route() do
      {:ok,
       %{
         profile: profile,
         provider: model_profile.provider,
         chain: chain,
         settings: [provider_setting, task_setting],
         disclosure: disclosure_result(context)
       }}
    end
  end

  def select(_profile, _context), do: {:error, :invalid_model_profile}

  @doc "Move one profile to the DirectAnswer head without rewriting its authored tail."
  @spec chain_with_head(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def chain_with_head(profile) when is_binary(profile) and profile != "" do
    with {:ok, user_settings} <- Settings.read_user_settings() do
      tail =
        case Schema.get_dotted(user_settings, "model_preferences.tasks.direct_answer") do
          profiles when is_list(profiles) -> profiles
          _absent -> []
        end

      {:ok, [profile | Enum.reject(tail, &(&1 == profile))]}
    end
  end

  def chain_with_head(_profile), do: {:error, :invalid_model_profile}

  defp validate_text_profile(%{name: profile} = model_profile) do
    if ModelCapabilities.runtime_text_generation?(model_profile) do
      :ok
    else
      {:error, {:profile_missing_capability, profile, "text_generation"}}
    end
  end

  defp disclosure_result(context) do
    enabled? = match?({:ok, true}, Settings.get("intent.direct_answer_model_enabled"))
    surface = Disclosure.disclosure_surface(context)

    %{
      status: if(enabled?, do: :reconciled, else: :dormant),
      surface: surface,
      pending?: enabled? and not is_nil(surface) and Disclosure.pending?(surface),
      hosted_pending?: enabled? and not is_nil(surface) and Disclosure.hosted_pending?(surface)
    }
  end
end
