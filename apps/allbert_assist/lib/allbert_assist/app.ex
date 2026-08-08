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

  @type memory_namespace_declaration :: %{
          required(:app_id) => atom(),
          required(:namespace) => atom(),
          required(:writable) => boolean(),
          optional(:description) => String.t()
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
  @callback memory_namespace() :: memory_namespace_declaration() | nil
  @callback surfaces() :: [surface_entry() | AllbertAssist.Surface.t()]
  @optional_callbacks memory_namespace: 0

  defmacro __using__(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
             Enum.all?(Keyword.keys(opts), &(&1 in [:default?, :reserved?])) and
             Enum.all?(Keyword.values(opts), &is_boolean/1) do
      raise ArgumentError, "invalid Allbert App owner declarations: #{inspect(opts)}"
    end

    default_owner = Keyword.get(opts, :default?, false)
    reserved_owner = Keyword.get(opts, :reserved?, false)

    quote bind_quoted: [default_owner: default_owner, reserved_owner: reserved_owner] do
      @behaviour AllbertAssist.App
      @allbert_app_default default_owner
      @allbert_app_reserved reserved_owner

      @doc false
      def allbert_app?, do: true

      @doc false
      def default_app?, do: @allbert_app_default

      @doc false
      def reserved_app_id?, do: @allbert_app_reserved

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
      def memory_namespace, do: nil

      @impl AllbertAssist.App
      def surfaces, do: []

      defoverridable child_spec: 1,
                     agents: 0,
                     actions: 0,
                     signals: 0,
                     skill_paths: 0,
                     settings_schema: 0,
                     memory_namespace: 0,
                     surfaces: 0
    end
  end
end
