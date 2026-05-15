defmodule AllbertAssist.Plugin.Entry do
  @moduledoc """
  Normalized volatile plugin registry entry.
  """

  @enforce_keys [:plugin_id, :display_name, :version, :kind, :source, :status, :trust_status]
  defstruct [
    :plugin_id,
    :display_name,
    :version,
    :kind,
    :source,
    :status,
    :trust_status,
    :module,
    :root_path,
    :manifest_path,
    apps: [],
    channels: [],
    actions: [],
    skill_paths: [],
    settings_schema: [],
    children: :ignore,
    diagnostics: []
  ]

  @type source :: :shipped | :project | :home
  @type status :: :enabled | :disabled | :invalid | :rejected
  @type trust_status :: :trusted | :pending | :untrusted

  @type t :: %__MODULE__{
          plugin_id: String.t(),
          display_name: String.t(),
          version: String.t(),
          kind: String.t(),
          source: source(),
          status: status(),
          trust_status: trust_status(),
          module: module() | nil,
          root_path: Path.t() | nil,
          manifest_path: Path.t() | nil,
          apps: [module()],
          channels: [map()],
          actions: [module()],
          skill_paths: [Path.t()],
          settings_schema: [map()],
          children: Supervisor.child_spec() | :ignore,
          diagnostics: [map()]
        }

  @doc "Return trace- and CLI-safe plugin metadata."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = entry) do
    %{
      plugin_id: entry.plugin_id,
      display_name: entry.display_name,
      version: entry.version,
      kind: entry.kind,
      source: entry.source,
      status: entry.status,
      trust_status: entry.trust_status,
      module: entry.module,
      root_path: entry.root_path,
      manifest_path: entry.manifest_path,
      contributions: %{
        apps: length(entry.apps),
        channels: length(entry.channels),
        actions: length(entry.actions),
        skill_paths: length(entry.skill_paths),
        settings_schema: length(entry.settings_schema),
        child_spec: entry.children != :ignore
      },
      diagnostics: entry.diagnostics
    }
  end
end
