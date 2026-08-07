defmodule AllbertAssist.CLI.EntryPlan do
  @moduledoc """
  Read-only classification of one top-level Allbert CLI invocation.

  The plan is residual-owned so composition can orchestrate attach/bootstrap
  without copying the command table or depending on command implementation.
  """

  @enforce_keys [:schema_version, :argv, :disposition, :route, :first_run_state]
  defstruct @enforce_keys

  @type disposition :: :license_view | :runtime_free | :runtime_required
  @type route :: :licenses | :first_run | :command
  @type first_run_state ::
          :not_applicable
          | :home_missing
          | :schema_incompatible
          | :onboarding_incomplete
          | :provider_probe_required

  @type t :: %__MODULE__{
          schema_version: 1,
          argv: [String.t()],
          disposition: disposition(),
          route: route(),
          first_run_state: first_run_state()
        }
end
