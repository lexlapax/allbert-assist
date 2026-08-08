defmodule AllbertAssist.Kernel.Contract.Membership do
  @moduledoc """
  App and Plugin membership facts for the relocated Registry and Runner.

  Membership answers "which app or plugin owns this action" and "is this a known
  app". It is metadata, never authority: a positive answer decorates capability
  metadata or satisfies a scope check that Security still has to allow
  separately.

  Unbound, ownership is unknown (`nil`) and `known_app_id?/2` is `false`. Both
  are the conservative direction — an unattributed capability rather than a
  misattributed one, and a refused app scope rather than an assumed one.
  """

  alias AllbertAssist.Kernel.Contract

  @callback app_id_for_action(module(), keyword()) :: atom() | nil
  @callback plugin_id_for_action(module(), keyword()) :: String.t() | atom() | nil
  @callback known_app_id?(atom(), keyword()) :: boolean()
  @callback registered_plugins(keyword()) :: [term()]

  @doc "The app that contributed `module`, or nil."
  @spec app_id_for_action(module(), keyword()) :: atom() | nil
  def app_id_for_action(module, opts), do: call(:app_id_for_action, [module, opts], nil)

  @doc "The plugin that contributed `module`, or nil."
  @spec plugin_id_for_action(module(), keyword()) :: String.t() | atom() | nil
  def plugin_id_for_action(module, opts), do: call(:plugin_id_for_action, [module, opts], nil)

  @doc "True when `app_id` is a registered app."
  @spec known_app_id?(atom(), keyword()) :: boolean()
  def known_app_id?(app_id, opts), do: call(:known_app_id?, [app_id, opts], false)

  @doc "Registered plugin entries, used for release-availability evaluation."
  @spec registered_plugins(keyword()) :: [term()]
  def registered_plugins(opts), do: call(:registered_plugins, [opts], [])

  defp call(fun, args, closed) do
    case Contract.fetch(:membership) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
