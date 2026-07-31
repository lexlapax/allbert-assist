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

  @type readiness ::
          :ready | :needs_model | :needs_runtime | :needs_review | :needs_selection

  @doc "Project DirectAnswer availability separately from first-model substrate readiness."
  @spec readiness(%{required(:state) => state(), required(:model_state) => atom()}) :: readiness()
  def readiness(%{state: :auto_enabled}), do: :ready
  def readiness(%{state: :enabled_unavailable}), do: :needs_selection
  def readiness(%{state: :needs_model, model_state: :runtime_unhealthy}), do: :needs_runtime
  def readiness(%{state: :needs_model}), do: :needs_model
  def readiness(%{state: :nothing_detected}), do: :needs_runtime
  def readiness(%{state: :below_floor}), do: :needs_review
  def readiness(%{state: :sticky_disabled, availability: :available}), do: :ready

  def readiness(%{state: :sticky_disabled, model_state: model_state}),
    do: unavailable_readiness(model_state)

  @doc "Project the legacy six-state substrate without interpreting DirectAnswer availability."
  @spec substrate(atom()) :: :ready | :needs_model | :needs_runtime | :needs_review
  def substrate(:local_ready), do: :ready
  def substrate(:byok_ready), do: :ready
  def substrate(:runtime_missing), do: :needs_runtime
  def substrate(:runtime_unhealthy), do: :needs_runtime
  def substrate(:model_missing), do: :needs_model
  def substrate(:below_hardware_floor), do: :needs_review

  defp unavailable_readiness(model_state) when model_state in [:local_ready, :byok_ready],
    do: :needs_selection

  defp unavailable_readiness(model_state), do: substrate(model_state)

  @spec for(%{required(:state) => state(), required(:model_state) => atom()}, :web | :tui | :cli) ::
          %{message: String.t(), primary_ctas: [atom()]}
  def unquote(:for)(%{state: state, model_state: model_state} = result, surface)
      when surface in @surfaces do
    cta = primary_cta(state, model_state)

    %{
      message: message(state, model_state, surface),
      readiness: readiness(result),
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
  defp primary_cta(:enabled_unavailable, _model_state), do: :select_model

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
