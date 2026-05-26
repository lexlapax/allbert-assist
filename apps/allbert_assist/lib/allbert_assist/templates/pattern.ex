defmodule AllbertAssist.Templates.Pattern do
  @moduledoc """
  Behaviour for reviewed v0.38 templated-creation patterns.

  Pattern modules are metadata and reviewed template-file declarations. They do
  not grant compile, route, permission, schedule, provider, or live-loader
  authority by themselves.
  """

  @type parameter_entry :: %{
          required(:name) => String.t() | atom(),
          required(:type) => :string | :boolean | :enum | {:list, :string},
          optional(:required) => boolean(),
          optional(:default) => term(),
          optional(:min_length) => non_neg_integer(),
          optional(:max_length) => pos_integer(),
          optional(:allowed_values) => [String.t()],
          optional(:pattern) => Regex.t(),
          optional(:description) => String.t()
        }

  @type file_spec :: %{
          required(:target) => String.t(),
          optional(:source) => String.t(),
          optional(:content) => String.t(),
          optional(:mode) => :text
        }

  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback description() :: String.t()
  @callback parameter_schema() :: [parameter_entry()]
  @callback files() :: [file_spec()]
  @callback target_shapes() :: [String.t()]
  @callback live_integration?() :: boolean()

  @callback template_root() :: String.t() | nil
  @callback validation_profile() :: String.t() | nil
  @callback normalize_params(map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks template_root: 0, validation_profile: 0, normalize_params: 1
end
