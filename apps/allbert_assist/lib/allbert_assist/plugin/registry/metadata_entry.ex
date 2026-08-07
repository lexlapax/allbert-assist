defmodule AllbertAssist.Plugin.Registry.MetadataEntry do
  @moduledoc """
  Immutable, effect-free Plugin Registry input captured for one Pack generation.

  Presentation diagnostics, manifest paths, and release availability are
  deliberately excluded. `root_path` remains operational containment input.
  """

  @fields [
    :plugin_id,
    :display_name,
    :source,
    :status,
    :trust_status,
    :module,
    :apps,
    :channels,
    :actions,
    :root_path,
    :skill_paths,
    :settings_schema,
    :children
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          plugin_id: String.t(),
          display_name: String.t(),
          source: atom(),
          status: atom(),
          trust_status: atom(),
          module: module() | nil,
          apps: [module()],
          channels: [map()],
          actions: [module()],
          root_path: Path.t() | nil,
          skill_paths: [Path.t()],
          settings_schema: [map()],
          children: term()
        }

  @spec from_entry(map()) :: t()
  def from_entry(entry) when is_map(entry) do
    struct!(__MODULE__, Map.take(entry, @fields))
  end
end
