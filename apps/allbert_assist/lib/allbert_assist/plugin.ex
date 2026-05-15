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
  @callback child_spec(opts :: keyword() | map()) :: Supervisor.child_spec() | :ignore

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
      def child_spec(_opts), do: :ignore

      defoverridable apps: 0,
                     channels: 0,
                     actions: 0,
                     skill_paths: 0,
                     settings_schema: 0,
                     child_spec: 1
    end
  end
end
