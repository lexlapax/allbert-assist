defmodule AllbertAssist.DevGates.V14M0LedgerPlugin do
  @moduledoc """
  The registration subject for the M0 registry ledger's mutation proof.

  The ledger exercises register-then-duplicate-register against an isolated
  registry. The subject is incidental to what that proves, and for most of v1.4
  it was simply whichever shipped plugin happened to be compiled into the
  residual: `AllbertAssist.Plugins.Telegram` until M12 extracted it, then
  `AllbertAssist.Plugins.Discord`.

  M13 removed that option for good. Every plugin is now its own application, so
  there is no shipped plugin left in the residual to borrow — and borrowing one
  from a pack is the residual-to-pack edge the R0 DAG forbids. A gate that needs
  a subject now owns one.

  Deliberately minimal and deliberately inert: no apps, no actions, no channels,
  no settings, no child. It exists to be registered twice and rejected the second
  time, and anything else it contributed would enter the frozen payload for no
  reason. It is never discovered — `Plugin.Discovery` scans manifests and
  compiled plugin inventories, and this module appears in neither — so it cannot
  leak into a product registry.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.v14_m0_ledger"

  @impl true
  def display_name, do: "v1.4 M0 ledger subject"

  @impl true
  def version, do: "1.4.0"

  @impl true
  def validate(_opts), do: :ok
end
