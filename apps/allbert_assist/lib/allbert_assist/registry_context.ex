defmodule AllbertAssist.RegistryContext do
  @moduledoc false

  # v1.0.2 M2 (ADR 0082): one optional, internal registry-context keyword that
  # registry-reading functions carry inside their `opts`:
  #
  #     app: [server: pid_or_name],
  #     plugin: [server: pid_or_name],
  #     actions_overlay: server
  #
  # Omission means the current global defaults, so production call sites pass
  # nothing and behave identically. The context only selects WHERE registrations
  # are read from — it never bypasses registration, permission, confirmation, or
  # Settings-schema authority — and it is never accepted from serialized params,
  # channels, public protocols, or operator surfaces.

  @context_keys [:app, :plugin, :actions_overlay]

  @doc "Return the `AllbertAssist.App.Registry` option list carried in `opts`."
  @spec app_opts(keyword()) :: keyword()
  def app_opts(opts) when is_list(opts), do: Keyword.get(opts, :app, [])

  @doc "Return the `AllbertAssist.Plugin.Registry` option list carried in `opts`."
  @spec plugin_opts(keyword()) :: keyword()
  def plugin_opts(opts) when is_list(opts), do: Keyword.get(opts, :plugin, [])

  @doc "Return the `DynamicPlugins.ActionsOverlay` server carried in `opts`."
  @spec overlay_server(keyword()) :: GenServer.server()
  def overlay_server(opts) when is_list(opts) do
    Keyword.get(opts, :actions_overlay, AllbertAssist.DynamicPlugins.ActionsOverlay)
  end

  @doc "Take only the registry-context keys for forwarding through layers."
  @spec take(keyword()) :: keyword()
  def take(opts) when is_list(opts), do: Keyword.take(opts, @context_keys)
end
