defmodule AllbertAssist.Pack.CandidateBuilder.RowFamilies do
  @moduledoc """
  Explicit intermediate contract between CandidateBuilder row-family adapters.

  Every callback family is a map of Pack owner id to ordered `Pack.Row` values.
  A builder must provide every family, including an explicit empty map. This
  prevents a partial adapter from silently producing a canonical-but-incomplete
  Candidate during the M1.a3 transition.
  """

  alias AllbertAssist.Pack.Row

  @families [
    :apps,
    :actions,
    :settings_fragments,
    :settings_migrations,
    :channels,
    :surfaces,
    :skill_roots,
    :home_roots,
    :jobs,
    :stores,
    :prompt_rules,
    :intent_descriptors,
    :cli_groups,
    :release_assets,
    :test_lanes
  ]

  @enforce_keys @families
  defstruct @enforce_keys

  @type family ::
          :apps
          | :actions
          | :settings_fragments
          | :settings_migrations
          | :channels
          | :surfaces
          | :skill_roots
          | :home_roots
          | :jobs
          | :stores
          | :prompt_rules
          | :intent_descriptors
          | :cli_groups
          | :release_assets
          | :test_lanes
  @type rows_by_owner :: %{required(String.t()) => [Row.t()]}
  @type t :: %__MODULE__{
          apps: rows_by_owner(),
          actions: rows_by_owner(),
          settings_fragments: rows_by_owner(),
          settings_migrations: rows_by_owner(),
          channels: rows_by_owner(),
          surfaces: rows_by_owner(),
          skill_roots: rows_by_owner(),
          home_roots: rows_by_owner(),
          jobs: rows_by_owner(),
          stores: rows_by_owner(),
          prompt_rules: rows_by_owner(),
          intent_descriptors: rows_by_owner(),
          cli_groups: rows_by_owner(),
          release_assets: rows_by_owner(),
          test_lanes: rows_by_owner()
        }

  @spec families() :: [family(), ...]
  def families, do: @families

  @spec empty() :: t()
  def empty, do: struct!(__MODULE__, Map.new(@families, &{&1, %{}}))

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = value) do
    Enum.all?(@families, fn family ->
      value
      |> Map.fetch!(family)
      |> is_map()
    end)
  end

  def valid?(_value), do: false
end
