defmodule AllbertAssist.Pack.Contracts.ActionsOverlay do
  @moduledoc """
  Residual provider for the kernel `ActionsOverlay` contract.

  This module owns the overlay server default that `RegistryContext` used to
  carry. The default names a residual GenServer, so it belongs on the residual
  side of the seam rather than travelling into the kernel with the rest of the
  registry-context accessors.
  """

  @behaviour AllbertAssist.Kernel.Contract.ActionsOverlay

  alias AllbertAssist.DynamicPlugins.ActionsOverlay

  @impl true
  def modules(opts), do: ActionsOverlay.modules(overlay_server(opts))

  @impl true
  def agent_modules(opts), do: ActionsOverlay.agent_modules(overlay_server(opts))

  @impl true
  def actions_for_app(app_id, opts),
    do: ActionsOverlay.actions_for_app(app_id, overlay_server(opts))

  @impl true
  def diagnostics(opts), do: ActionsOverlay.diagnostics(overlay_server(opts))

  @impl true
  def overlay_server(opts) when is_list(opts),
    do: Keyword.get(opts, :actions_overlay, ActionsOverlay)

  def overlay_server(_opts), do: ActionsOverlay
end
