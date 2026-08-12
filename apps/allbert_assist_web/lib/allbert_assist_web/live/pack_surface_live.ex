defmodule AllbertAssistWeb.PackSurfaceLive do
  @moduledoc """
  The one routed LiveView that hosts every pack-contributed web surface.

  Web owns and routes this module; it names no pack. The `:pack` path segment
  selects a contributed surface through `AllbertAssistWeb.PackSurfaces`, and the
  lifecycle is delegated to that module. That inversion is what lets a pack
  depend on Web without Web depending back — see `AllbertAssist.Pack.WebSurface`
  for why a Phoenix router leaves no other option.

  The delegate module is kept in a private assign rather than the socket's
  `view`, because `render/1` receives assigns and not the socket and has no other
  way to find its target.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssistWeb.PackSurfaces

  @assign :__pack_surface_module__

  @impl true
  def mount(%{"pack" => surface_id} = params, session, socket) do
    case PackSurfaces.fetch(surface_id) do
      {:ok, module} ->
        socket
        |> assign(@assign, module)
        |> then(&module.mount(params, session, &1))
        |> normalize_mount()

      :error ->
        {:ok, redirect(put_flash(socket, :error, "Unknown app surface."), to: "/")}
    end
  end

  # A surface is addressed by its id, so a route without one cannot resolve.
  def mount(_params, _session, socket) do
    {:ok, redirect(put_flash(socket, :error, "Unknown app surface."), to: "/")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    delegate(socket, :handle_params, [params, uri], {:noreply, socket})
  end

  @impl true
  def handle_event(event, params, socket) do
    delegate(socket, :handle_event, [event, params], {:noreply, socket})
  end

  # A surface's own process messages reach it the same way; without this a
  # delegate that sends itself an async result would silently drop it.
  @impl true
  def handle_info(message, socket) do
    delegate(socket, :handle_info, [message], {:noreply, socket})
  end

  @impl true
  def render(assigns) do
    assigns
    |> Map.fetch!(@assign)
    |> apply(:render, [assigns])
  end

  # The surface receives the socket LAST, matching the LiveView callbacks it is
  # standing in for, so a delegate body can be moved across unchanged.
  defp delegate(socket, callback, args, fallback) do
    module = socket.assigns[@assign]

    if module && function_exported?(module, callback, length(args) + 1) do
      apply(module, callback, args ++ [socket])
    else
      fallback
    end
  end

  defp normalize_mount({:ok, socket}), do: {:ok, socket}
  defp normalize_mount({:ok, socket, opts}), do: {:ok, socket, opts}
end
