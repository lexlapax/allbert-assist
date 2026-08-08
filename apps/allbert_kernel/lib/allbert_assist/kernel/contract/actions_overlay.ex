defmodule AllbertAssist.Kernel.Contract.ActionsOverlay do
  @moduledoc """
  The confirmed dynamic-plugin action overlay, for the relocated Registry.

  The overlay stays outside static Pack composition because its loader lifecycle
  is a confirmed operator action rather than a build fact, and it keeps its
  documented final precedence. What the kernel must not do is reach into the
  residual to find it, so the overlay arrives as a bound port and remains
  composition-validated authority rather than becoming a kernel pack lookup.

  Unbound, the overlay is empty. An empty overlay removes dynamic actions from
  resolution rather than adding any, so no action becomes reachable that
  composition did not admit.
  """

  alias AllbertAssist.Kernel.Contract

  @callback modules(keyword()) :: [module()]
  @callback agent_modules(keyword()) :: [module()]
  @callback actions_for_app(atom(), keyword()) :: [module()]
  @callback diagnostics(keyword()) :: [map()]
  @callback overlay_server(keyword()) :: term()

  @doc "Overlay action modules."
  @spec modules(keyword()) :: [module()]
  def modules(opts), do: call(:modules, [opts], [])

  @doc "Overlay action modules exposed to the intent agent."
  @spec agent_modules(keyword()) :: [module()]
  def agent_modules(opts), do: call(:agent_modules, [opts], [])

  @doc "Overlay action modules contributed by one registered app."
  @spec actions_for_app(atom(), keyword()) :: [module()]
  def actions_for_app(app_id, opts), do: call(:actions_for_app, [app_id, opts], [])

  @doc "Overlay registry diagnostics."
  @spec diagnostics(keyword()) :: [map()]
  def diagnostics(opts), do: call(:diagnostics, [opts], [])

  @doc """
  Resolve the overlay server named in `opts`.

  The default server name belongs to the provider, not the kernel; resolving it
  here is what keeps the residual overlay module out of kernel source.
  """
  @spec overlay_server(keyword()) :: term()
  def overlay_server(opts), do: call(:overlay_server, [opts], nil)

  defp call(fun, args, closed) do
    case Contract.fetch(:actions_overlay) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
