defmodule AllbertAssist.Plugin do
  @moduledoc """
  Local package and discovery contract for Allbert extension contributions.

  A plugin contributes contract data. It does not grant trust, permissions,
  confirmation bypasses, dynamic code loading, or runtime authority.
  """

  @type diagnostic :: %{
          required(:kind) => atom(),
          required(:message) => String.t(),
          optional(:detail) => map()
        }

  @callback plugin_id() :: String.t()
  @callback display_name() :: String.t()
  @callback version() :: String.t()
  @callback validate(opts :: keyword() | map()) :: :ok | {:error, [diagnostic()]}
  @callback apps() :: [module()]
  @callback channels() :: [map()]
  @callback actions() :: [module()]
  @callback skill_paths() :: [Path.t()]
  @callback settings_schema() :: [map()]
  @callback release_availability() :: [map()]
  @callback child_spec(opts :: keyword() | map()) :: Supervisor.child_spec() | :ignore

  @doc """
  Whether this module is one of the product's own plugins.

  Implementing this behaviour used to be the same statement as being a product
  plugin, because for the product's whole history the only modules that did were
  the shipped ones. v1.4 M13 broke that coincidence: the M0 registry ledger needs
  a subject to register twice, and a gate fixture that implements the behaviour
  is not a plugin the product ships. Inferring product membership from the
  behaviour alone silently admitted that fixture to
  `AllbertAssist.Pack.CompiledInventory.plugin_modules/1`, and from there to
  `AllbertAssist.Plugin.Discovery.shipped_modules/0`, which is production code.

  So a module states its intent rather than having it inferred. The default is
  `true`, which keeps adding a plugin a one-file change with nothing to register
  here, and means a missing declaration can never hide a real plugin -- only a
  fixture opting out deliberately is excluded.
  """
  @callback product?() :: boolean()

  defmacro __using__(_opts) do
    quote do
      @behaviour AllbertAssist.Plugin

      @impl AllbertAssist.Plugin
      def apps, do: []

      @impl AllbertAssist.Plugin
      def channels, do: []

      @impl AllbertAssist.Plugin
      def actions, do: []

      @impl AllbertAssist.Plugin
      def skill_paths, do: []

      @impl AllbertAssist.Plugin
      def settings_schema, do: []

      @impl AllbertAssist.Plugin
      def release_availability, do: []

      @impl AllbertAssist.Plugin
      def child_spec(_opts), do: :ignore

      @impl AllbertAssist.Plugin
      def product?, do: true

      defoverridable apps: 0,
                     channels: 0,
                     actions: 0,
                     skill_paths: 0,
                     settings_schema: 0,
                     release_availability: 0,
                     child_spec: 1,
                     product?: 0
    end
  end
end
