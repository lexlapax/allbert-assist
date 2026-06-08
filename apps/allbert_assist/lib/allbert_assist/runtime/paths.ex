defmodule AllbertAssist.Runtime.Paths do
  @moduledoc """
  Runtime-facing Allbert Home path facade.

  This module is the v0.31 path entrypoint for new runtime, app, plugin,
  workspace, and future sandbox-trial code. It preserves the existing
  `AllbertAssist.Paths` locations and configuration semantics while giving
  downstream milestones one obvious place to add new Allbert Home roots.
  """

  alias AllbertAssist.Paths

  @type root_name ::
          :home
          | :settings
          | :memory
          | :memory_deleted
          | :artifacts
          | :audio
          | :images
          | :generated_images
          | :confirmations
          | :execution
          | :package_installs
          | :external
          | :external_cache
          | :database
          | :skills
          | :cache
          | :online_skill_sources
          | :tmp
          | :workspace
          | :workspace_canvas
          | :workspace_ephemeral
          | :workspace_secrets
          | :themes
          | :theme_snippets
          | :dynamic_plugins
          | :dynamic_plugins_drafts
          | :dynamic_plugins_integrated

  @doc "Return the canonical Allbert Home."
  @spec home() :: String.t()
  defdelegate home(), to: Paths

  @doc "Create Allbert Home and the standard child directories."
  @spec ensure_home!() :: String.t()
  defdelegate ensure_home!(), to: Paths

  @doc "Return the Settings Central root."
  @spec settings_root() :: String.t()
  defdelegate settings_root(), to: Paths

  @doc "Return the markdown memory root."
  @spec memory_root() :: String.t()
  defdelegate memory_root(), to: Paths

  @doc "Return the archived deleted-memory root."
  @spec memory_deleted_root() :: String.t()
  defdelegate memory_deleted_root(), to: Paths

  @doc "Return the artifact content-addressable store root."
  @spec artifacts_root() :: String.t()
  defdelegate artifacts_root(), to: Paths

  @doc "Return the legacy retained-audio root used as an artifact backfill input."
  @spec audio_root() :: String.t()
  defdelegate audio_root(), to: Paths

  @doc "Return the legacy retained vision-input image root used as an artifact backfill input."
  @spec images_root() :: String.t()
  defdelegate images_root(), to: Paths

  @doc "Return the legacy generated-image root used as an artifact backfill input."
  @spec generated_images_root() :: String.t()
  defdelegate generated_images_root(), to: Paths

  @doc "Return the durable confirmation request root."
  @spec confirmations_root() :: String.t()
  defdelegate confirmations_root(), to: Paths

  @doc "Return the local execution runtime root."
  @spec execution_root() :: String.t()
  defdelegate execution_root(), to: Paths

  @doc "Return the package installation execution root."
  @spec package_installs_root() :: String.t()
  defdelegate package_installs_root(), to: Paths

  @doc "Return the external service adapter root."
  @spec external_root() :: String.t()
  defdelegate external_root(), to: Paths

  @doc "Return the external service response/cache root."
  @spec external_cache_root() :: String.t()
  defdelegate external_cache_root(), to: Paths

  @doc "Return the local SQLite database path."
  @spec db_path() :: String.t()
  defdelegate db_path(), to: Paths

  @doc "Return the user-owned Agent Skills root."
  @spec skills_root() :: String.t()
  defdelegate skills_root(), to: Paths

  @doc "Return the Allbert cache root."
  @spec cache_root() :: String.t()
  defdelegate cache_root(), to: Paths

  @doc "Return the disabled imported-skill source cache root."
  @spec online_skill_sources_root() :: String.t()
  defdelegate online_skill_sources_root(), to: Paths

  @doc "Return the Allbert temporary runtime root."
  @spec tmp_root() :: String.t()
  defdelegate tmp_root(), to: Paths

  @doc "Return the workspace substrate root."
  @spec workspace_root() :: String.t()
  defdelegate workspace_root(), to: Paths

  @doc "Return the workspace canvas body root."
  @spec workspace_canvas_root() :: String.t()
  defdelegate workspace_canvas_root(), to: Paths

  @doc "Return the workspace ephemeral surface body root."
  @spec workspace_ephemeral_root() :: String.t()
  defdelegate workspace_ephemeral_root(), to: Paths

  @doc "Return the workspace secret root."
  @spec workspace_secrets_root() :: String.t()
  defdelegate workspace_secrets_root(), to: Paths

  @doc "Return the operator theme root."
  @spec themes_root() :: String.t()
  defdelegate themes_root(), to: Paths

  @doc "Return the operator CSS snippet root."
  @spec theme_snippets_root() :: String.t()
  defdelegate theme_snippets_root(), to: Paths

  @doc "Return the dynamic plugin substrate root."
  @spec dynamic_plugins_root() :: String.t()
  defdelegate dynamic_plugins_root(), to: Paths

  @doc "Return the inert dynamic draft root."
  @spec dynamic_plugins_drafts_root() :: String.t()
  defdelegate dynamic_plugins_drafts_root(), to: Paths

  @doc "Return the reviewed dynamic integration root."
  @spec dynamic_plugins_integrated_root() :: String.t()
  defdelegate dynamic_plugins_integrated_root(), to: Paths

  @doc "Return a named root path."
  @spec root(root_name()) :: String.t()
  def root(:home), do: home()
  def root(:settings), do: settings_root()
  def root(:memory), do: memory_root()
  def root(:memory_deleted), do: memory_deleted_root()
  def root(:artifacts), do: artifacts_root()
  def root(:audio), do: audio_root()
  def root(:images), do: images_root()
  def root(:generated_images), do: generated_images_root()
  def root(:confirmations), do: confirmations_root()
  def root(:execution), do: execution_root()
  def root(:package_installs), do: package_installs_root()
  def root(:external), do: external_root()
  def root(:external_cache), do: external_cache_root()
  def root(:database), do: db_path()
  def root(:skills), do: skills_root()
  def root(:cache), do: cache_root()
  def root(:online_skill_sources), do: online_skill_sources_root()
  def root(:tmp), do: tmp_root()
  def root(:workspace), do: workspace_root()
  def root(:workspace_canvas), do: workspace_canvas_root()
  def root(:workspace_ephemeral), do: workspace_ephemeral_root()
  def root(:workspace_secrets), do: workspace_secrets_root()
  def root(:themes), do: themes_root()
  def root(:theme_snippets), do: theme_snippets_root()
  def root(:dynamic_plugins), do: dynamic_plugins_root()
  def root(:dynamic_plugins_drafts), do: dynamic_plugins_drafts_root()
  def root(:dynamic_plugins_integrated), do: dynamic_plugins_integrated_root()

  @doc "Return the current standard root vocabulary as a map."
  @spec roots() :: %{root_name() => String.t()}
  def roots do
    %{
      home: home(),
      settings: settings_root(),
      memory: memory_root(),
      memory_deleted: memory_deleted_root(),
      artifacts: artifacts_root(),
      audio: audio_root(),
      images: images_root(),
      generated_images: generated_images_root(),
      confirmations: confirmations_root(),
      execution: execution_root(),
      package_installs: package_installs_root(),
      external: external_root(),
      external_cache: external_cache_root(),
      database: db_path(),
      skills: skills_root(),
      cache: cache_root(),
      online_skill_sources: online_skill_sources_root(),
      tmp: tmp_root(),
      workspace: workspace_root(),
      workspace_canvas: workspace_canvas_root(),
      workspace_ephemeral: workspace_ephemeral_root(),
      workspace_secrets: workspace_secrets_root(),
      themes: themes_root(),
      theme_snippets: theme_snippets_root(),
      dynamic_plugins: dynamic_plugins_root(),
      dynamic_plugins_drafts: dynamic_plugins_drafts_root(),
      dynamic_plugins_integrated: dynamic_plugins_integrated_root()
    }
  end
end
