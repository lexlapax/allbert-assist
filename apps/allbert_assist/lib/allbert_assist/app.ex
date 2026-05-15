defmodule AllbertAssist.App do
  @moduledoc """
  Public contract for Allbert workspace apps.

  Apps declare identity, validation, optional supervision, agents, actions,
  signals, skill paths, settings schema, and navigation display entries. App
  registration is contract data, not authority.
  """

  @type diagnostic :: %{
          required(:kind) => atom(),
          required(:message) => String.t(),
          optional(:detail) => map()
        }

  @type surface_entry :: %{
          required(:id) => atom(),
          required(:label) => String.t(),
          required(:path) => String.t(),
          required(:app_id) => atom(),
          optional(:icon) => String.t() | nil,
          optional(:description) => String.t() | nil
        }

  @type schema_entry :: %{
          required(:key) => String.t(),
          required(:type) => atom(),
          optional(:default) => term(),
          optional(:description) => String.t(),
          optional(:secret?) => boolean()
        }

  @type signal_declarations :: %{
          required(:emits) => [String.t()],
          required(:subscribes) => [String.t()]
        }

  @callback app_id() :: atom()
  @callback display_name() :: String.t()
  @callback version() :: String.t()
  @callback validate(opts :: keyword() | map()) :: :ok | {:error, [diagnostic()]}
  @callback child_spec(opts :: keyword() | map()) :: Supervisor.child_spec() | :ignore
  @callback agents() :: [module()]
  @callback actions() :: [module()]
  @callback signals() :: signal_declarations()
  @callback skill_paths() :: [Path.t()]
  @callback settings_schema() :: [schema_entry()]
  @callback surfaces() :: [surface_entry() | AllbertAssist.Surface.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour AllbertAssist.App

      @impl AllbertAssist.App
      def child_spec(_opts), do: :ignore

      @impl AllbertAssist.App
      def actions, do: []

      @impl AllbertAssist.App
      def agents, do: []

      @impl AllbertAssist.App
      def signals, do: %{emits: [], subscribes: []}

      @impl AllbertAssist.App
      def skill_paths, do: []

      @impl AllbertAssist.App
      def settings_schema, do: []

      @impl AllbertAssist.App
      def surfaces, do: []

      defoverridable child_spec: 1,
                     agents: 0,
                     actions: 0,
                     signals: 0,
                     skill_paths: 0,
                     settings_schema: 0,
                     surfaces: 0
    end
  end
end
