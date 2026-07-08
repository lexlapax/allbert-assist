defmodule AllbertAssistWeb.Workspace.FirstRun do
  @moduledoc """
  v0.63 M5 — the web first-run auto-open decision.

  On workspace mount with no explicit destination, the shell opens the onboarding
  wizard automatically while the operator has not yet completed onboarding — i.e.
  `FirstRun.detect/0` is `:onboarding_incomplete` (or `:profile_unreviewed`, the
  post-completion profile-review gate). It deliberately does **not** auto-open on
  `:first_model_not_ready` (model setup is reachable from the normal surface) nor on
  the infrastructure states `:home_missing`/`:schema_incompatible` (a
  misconfiguration, not a first-run) — the wizard would loop uselessly there. Once
  onboarding is completed the wizard stops taking over the canvas. Pure + injectable
  so the decision is unit-tested without a LiveView.
  """

  alias AllbertAssist.CLI.FirstRun

  @auto_open_states [:onboarding_incomplete, :profile_unreviewed]

  @onboard_destination "workspace:onboard"

  @doc "The detect/0 states that auto-open the onboarding wizard."
  @spec auto_open_states() :: [FirstRun.state()]
  def auto_open_states, do: @auto_open_states

  @doc """
  Should the workspace auto-open onboarding? Reads `FirstRun.detect/0` by default;
  pass `:state` to inject. Any detection error resolves to `false` (never trap the
  operator in onboarding on a probe error).
  """
  @spec auto_open?(keyword()) :: boolean()
  def auto_open?(opts \\ []) do
    state = Keyword.get_lazy(opts, :state, &safe_detect/0)
    state in @auto_open_states
  end

  @doc "The onboarding canvas destination string."
  @spec onboard_destination() :: String.t()
  def onboard_destination, do: @onboard_destination

  defp safe_detect do
    FirstRun.detect()
  rescue
    _error -> :product_ready
  end
end
