defmodule AllbertAssist.Pack.Contracts.Membership do
  @moduledoc """
  Residual provider for the kernel `Membership` contract.

  App and Plugin ownership are two registries with one question each, so this
  adapter is where they are read together rather than the kernel knowing both.
  """

  @behaviour AllbertAssist.Kernel.Contract.Membership

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @impl true
  defdelegate app_id_for_action(module, opts), to: AppRegistry

  @impl true
  defdelegate plugin_id_for_action(module, opts), to: PluginRegistry

  @impl true
  defdelegate known_app_id?(app_id, opts), to: AppRegistry

  @impl true
  defdelegate registered_plugins(opts), to: PluginRegistry
end
