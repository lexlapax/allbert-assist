defmodule AllbertTUI.CLI do
  @moduledoc """
  `allbert admin channels tui ...` — owned by this pack (v1.4 M15.1).

  Every other extracted channel pack (`AllbertSlack.CLI`, `AllbertDiscord.CLI`,
  `AllbertMatrix.CLI`, `AllbertSignal.CLI`, `AllbertEmail.CLI`,
  `AllbertWhatsapp.CLI`, `AllbertTelegram.CLI`) owns real subcommands here --
  they each configure an external identity, bot token, or secret. The TUI
  channel does not: it is `trust_class: :local`, ships no `secret_refs`, and
  its one operator per Allbert Home authenticates through the local Attach
  socket, not a channel-specific credential. There is nothing this module
  could add beyond what `AllbertAssist.CLI.Areas.Channels` already provides
  generically (`list`, `show tui`, `status`, `--parity`, `setup-check tui`).

  This module exists so `allbert admin channels tui ...` resolves through the
  same `AllbertAssist.CLI.PackGroups` contributed-group mechanism every other
  channel pack uses, instead of being the one channel with no CLI group at
  all (`AllbertTUI.Pack.cli_groups/0`). The behavior is intentionally
  unchanged from before this group existed: any TUI-specific admin subcommand
  falls through to this same usage text, which points the operator at
  `allbert admin settings` (`channels.tui.*`) and the generic channel reads.
  """

  @behaviour AllbertAssist.CLI.Area

  alias AllbertAssist.CLI.Areas.Render

  @usage """
  Usage:
    allbert admin channels tui

  The TUI channel has no channel-specific administration commands. It is
  configured through `allbert admin settings` (`channels.tui.*`); use
  `allbert admin channels show tui` or `allbert admin channels setup-check tui`
  for status and readiness.
  """

  @impl true
  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(_argv, _context \\ nil), do: Render.usage(@usage)
end
