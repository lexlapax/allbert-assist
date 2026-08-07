defmodule AllbertAssist.App.Registry.MetadataEntry do
  @moduledoc """
  Immutable, effect-free App Registry input captured for one Pack generation.

  Runtime child pids and registration timestamps are deliberately excluded.
  """

  @fields [
    :app_id,
    :module,
    :display_name,
    :version,
    :agents,
    :actions,
    :signals,
    :skill_paths,
    :settings_schema,
    :memory_namespace,
    :surfaces,
    :surface_provider,
    :provider_surfaces,
    :surface_catalog,
    :child_id,
    :metadata
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          app_id: atom(),
          module: module(),
          display_name: String.t(),
          version: String.t(),
          agents: [module()],
          actions: [module()],
          signals: map(),
          skill_paths: [Path.t()],
          settings_schema: [map()],
          memory_namespace: map() | nil,
          surfaces: [map()],
          surface_provider: module() | nil,
          provider_surfaces: [term()],
          surface_catalog: [map()],
          child_id: term(),
          metadata: map()
        }

  @spec from_entry(map()) :: t()
  def from_entry(entry) when is_map(entry) do
    struct!(__MODULE__, Map.take(entry, @fields))
  end
end
