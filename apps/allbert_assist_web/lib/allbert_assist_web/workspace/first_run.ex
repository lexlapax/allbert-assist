defmodule AllbertAssistWeb.Workspace.FirstRun do
  @moduledoc """
  Web first-run auto-open decision.

  On workspace mount with no explicit destination, the shell opens the onboarding
  wizard while onboarding/profile review is incomplete. v0.64 adds the completed-
  onboarding-but-model-not-ready case: that opens the Models workspace repair panel,
  not the wizard. Infrastructure states (`:home_missing`/`:schema_incompatible`) still
  do not auto-open because they need install/upgrade repair, not an in-product loop.
  """

  alias AllbertAssist.CLI.FirstRun

  @auto_open_states [:onboarding_incomplete, :profile_unreviewed, :first_model_not_ready]

  @onboard_destination "workspace:onboard"
  @model_repair_destination "workspace:models"

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
    not is_nil(default_destination(opts))
  end

  @doc "The onboarding canvas destination string."
  @spec onboard_destination() :: String.t()
  def onboard_destination, do: @onboard_destination

  @doc "The standalone model-repair canvas destination string."
  @spec model_repair_destination() :: String.t()
  def model_repair_destination, do: @model_repair_destination

  @doc "The state-specific default destination, or nil when no first-run panel should open."
  @spec default_destination(keyword()) :: String.t() | nil
  def default_destination(opts \\ []) do
    case Keyword.get_lazy(opts, :state, &safe_detect/0) do
      state when state in [:onboarding_incomplete, :profile_unreviewed] -> @onboard_destination
      :first_model_not_ready -> @model_repair_destination
      _other -> nil
    end
  end

  defp safe_detect do
    FirstRun.detect()
  rescue
    _error -> :product_ready
  end
end
