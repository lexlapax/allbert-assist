defmodule AllbertAssist.FirstRun.Presentation do
  @moduledoc "Surface-neutral repair presentation for v1.2 first-run states."

  @surfaces [:web, :tui, :cli]

  @type state ::
          :auto_enabled
          | :sticky_disabled
          | :needs_model
          | :nothing_detected
          | :below_floor
          | :enabled_unavailable

  @spec for(%{required(:state) => state(), required(:model_state) => atom()}, :web | :tui | :cli) ::
          %{message: String.t(), primary_ctas: [atom()]}
  def unquote(:for)(%{state: state, model_state: model_state}, surface)
      when surface in @surfaces do
    cta = primary_cta(state, model_state)

    %{
      message: message(state, model_state, surface),
      primary_ctas: ctas(cta)
    }
  end

  defp ctas(nil), do: []
  defp ctas(cta), do: [cta]

  defp primary_cta(:auto_enabled, _model_state), do: nil
  defp primary_cta(:sticky_disabled, _model_state), do: nil
  defp primary_cta(:needs_model, :runtime_unhealthy), do: :repair_runtime
  defp primary_cta(:needs_model, _model_state), do: :pull_curated_model
  defp primary_cta(:nothing_detected, _model_state), do: :install_runtime
  defp primary_cta(:below_floor, _model_state), do: :configure_hosted_provider
  defp primary_cta(:enabled_unavailable, model_state), do: unavailable_cta(model_state)

  defp unavailable_cta(:runtime_unhealthy), do: :repair_runtime
  defp unavailable_cta(:model_missing), do: :pull_curated_model
  defp unavailable_cta(:below_hardware_floor), do: :configure_hosted_provider
  defp unavailable_cta(:local_ready), do: :select_model
  defp unavailable_cta(_model_state), do: :install_runtime

  defp message(:auto_enabled, _model_state, _surface), do: "Model answers are ready."

  defp message(:sticky_disabled, _model_state, _surface),
    do: "Model answers remain disabled by your saved setting."

  defp message(:needs_model, :runtime_unhealthy, _surface),
    do: "The local model runtime needs repair; bounded fallback chat remains available."

  defp message(:needs_model, _model_state, _surface),
    do: "The local runtime needs a model; bounded fallback chat remains available."

  defp message(:nothing_detected, _model_state, _surface),
    do:
      "No model runtime or hosted provider is configured; bounded fallback chat remains available."

  defp message(:below_floor, _model_state, _surface),
    do: "This machine is below the local model floor; bounded fallback chat remains available."

  defp message(:enabled_unavailable, _model_state, _surface),
    do: "The selected model is unavailable; bounded fallback chat remains available."
end
