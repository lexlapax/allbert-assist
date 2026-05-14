defmodule AllbertAssist.App do
  @moduledoc """
  Lite public contract for Allbert workspace apps.

  v0.15 keeps this deliberately small: apps declare identity, validation,
  optional supervision, action modules, skill paths, and navigation display
  entries. App registration is contract data, not authority.
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

  @callback app_id() :: atom()
  @callback display_name() :: String.t()
  @callback version() :: String.t()
  @callback validate(opts :: keyword() | map()) :: :ok | {:error, [diagnostic()]}
  @callback child_spec(opts :: keyword() | map()) :: Supervisor.child_spec() | :ignore
  @callback actions() :: [module()]
  @callback skill_paths() :: [Path.t()]
  @callback surfaces() :: [surface_entry()]

  defmacro __using__(_opts) do
    quote do
      @behaviour AllbertAssist.App

      @impl AllbertAssist.App
      def child_spec(_opts), do: :ignore

      @impl AllbertAssist.App
      def actions, do: []

      @impl AllbertAssist.App
      def skill_paths, do: []

      @impl AllbertAssist.App
      def surfaces, do: []

      defoverridable child_spec: 1, actions: 0, skill_paths: 0, surfaces: 0
    end
  end
end
