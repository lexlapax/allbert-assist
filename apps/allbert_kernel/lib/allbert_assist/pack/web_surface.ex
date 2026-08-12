defmodule AllbertAssist.Pack.WebSurface do
  @moduledoc """
  The contract a pack satisfies to own a routed web surface.

  ## Why this exists

  A Phoenix router resolves routes at compile time: `live/4` reads the target
  module's `__live__/0` while the router is being compiled. So for Web to route a
  pack's LiveView, Web must reference that module — and the module needs
  `AllbertAssistWeb`'s macros to render. Web depends on the pack, the pack
  depends on Web, and no amount of path fixing removes that cycle.

  v1.4 M13 breaks it by inverting what is routed. `AllbertAssistWeb.PackSurfaceLive`
  is a single generic LiveView that Web owns and routes. It resolves the pack's
  surface module from the sealed projection at mount and delegates the lifecycle
  to it. Web names no pack; each pack may therefore depend on Web, which is
  acyclic, and a pack keeps rendering with the same helpers it always used
  through `use AllbertAssistWeb, :html`.

  This is the same shape `cli_groups/0` took at M12 — a declared callback, rows
  read from the projection, a generic host in the residual — and it finally gives
  `surfaces/0` the consumer it has never had.

  ## Implementing

  A surface module declares `@behaviour AllbertAssist.Pack.WebSurface`, brings in
  `use AllbertAssistWeb, :html` for `~H` and the shared components, and imports
  whatever `Phoenix.LiveView` functions it calls (`push_patch/2`, `put_flash/3`
  and friends live there, not in `Phoenix.Component`). Its pack lists it from
  `surfaces/0` as `%{surface_id: "<id>", module: __MODULE__}`, and the `:pack`
  segment of the route path selects it by that id.

  `mount/3` and `render/1` are required because a surface that renders nothing is
  not a surface. `handle_params/3` and `handle_event/3` are optional; the host
  supplies inert defaults so a read-only surface declares nothing.
  """

  @type socket :: Phoenix.LiveView.Socket.t()

  @callback mount(params :: map(), session :: map(), socket()) ::
              {:ok, socket()} | {:ok, socket(), keyword()}

  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @callback handle_params(params :: map(), uri :: String.t(), socket()) ::
              {:noreply, socket()}

  @callback handle_event(event :: String.t(), params :: map(), socket()) ::
              {:noreply, socket()} | {:reply, map(), socket()}

  @callback handle_info(message :: term(), socket()) :: {:noreply, socket()}

  @optional_callbacks handle_params: 3, handle_event: 3, handle_info: 2
end
