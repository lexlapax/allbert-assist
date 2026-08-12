defmodule AllbertAssist.TestSupport.M0LedgerSubject do
  @moduledoc """
  The registration subject for the M0 registry ledger's mutation proof.

  The ledger exercises register-then-duplicate-register against an isolated
  registry. The subject is incidental to what that proves, and for most of v1.4
  it was simply whichever shipped plugin happened to be compiled into the
  residual: `AllbertAssist.Plugins.Telegram` until M12 extracted it, then
  `AllbertAssist.Plugins.Discord`.

  M13 removed that option for good. Every plugin is now its own application, so
  there is no shipped plugin left in the residual to borrow -- and borrowing one
  from a pack is the residual-to-pack edge the R0 DAG forbids. A gate that needs
  a subject owns one.

  It lives under `test/support` rather than `lib` because it is not part of the
  product, and the first attempt at it -- a `lib/allbert_assist/dev_gates`
  module -- proved the point by leaking: implementing the behaviour was enough to
  enter `AllbertAssist.Pack.CompiledInventory.plugin_modules/1`, and through it
  `AllbertAssist.Plugin.Discovery.shipped_modules/0`, which is production code.
  Two defences now stand where there were none: it is not compiled into a
  non-test build at all, and `product?/0` declares that it is not a product
  plugin even where it is compiled.

  Deliberately minimal and deliberately inert: no apps, no actions, no channels,
  no settings, no child. It exists to be registered twice and rejected the second
  time, and anything else it contributed would enter the frozen payload for no
  reason.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.m0_ledger_subject"

  @impl true
  def display_name, do: "v1.4 M0 ledger subject"

  @impl true
  def version, do: "1.4.0"

  @impl true
  def validate(_opts), do: :ok

  # Excluded from the compiled product inventory by its own declaration, so no
  # discovery path, allowlist, or fixture built from that inventory can mistake
  # a gate subject for a plugin the product ships.
  @impl true
  def product?, do: false
end
