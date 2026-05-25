defmodule AllbertAssist.Paths do
  @moduledoc """
  Resolves Allbert-owned local runtime paths.

  Allbert Home is the durable local root for settings, secrets, memory,
  databases, skills, caches, and temporary runtime files. Specific subsystem
  roots remain available as test, migration, compatibility, and operator escape
  hatches.

  v0.31 adds `AllbertAssist.Runtime.Paths` as the runtime-facing facade for
  new code. This module remains callable for compatibility and owns the
  existing path-resolution behavior until the facade fully absorbs it.
  """

  @app :allbert_assist

  @doc """
  Return the canonical Allbert Home.

  Precedence:

  1. `config :allbert_assist, AllbertAssist.Paths, home: "..."`
  2. `ALLBERT_HOME`
  3. `ALLBERT_HOME_DIR`
  4. `~/.allbert`
  """
  @spec home() :: String.t()
  def home do
    first_path(
      [configured(:home), env_path("ALLBERT_HOME"), env_path("ALLBERT_HOME_DIR")],
      Path.expand("~/.allbert")
    )
  end

  @doc "Create the Allbert Home directory and standard child directories."
  @spec ensure_home!() :: String.t()
  def ensure_home! do
    home = home()

    [
      home,
      settings_root(),
      Path.join(settings_root(), "audit"),
      confirmations_root(),
      Path.join(confirmations_root(), "pending"),
      Path.join(confirmations_root(), "resolved"),
      Path.join(confirmations_root(), "audit"),
      execution_root(),
      Path.join(execution_root(), "audit"),
      Path.join([execution_root(), "skill-scripts", "runs"]),
      package_installs_root(),
      Path.join(package_installs_root(), "audit"),
      Path.join(package_installs_root(), "runs"),
      sandbox_root(),
      sandbox_bundles_root(),
      sandbox_reports_root(),
      sandbox_cache_root(),
      sandbox_audit_root(),
      dynamic_plugins_root(),
      dynamic_plugins_drafts_root(),
      dynamic_plugins_integrated_root(),
      external_root(),
      Path.join(external_root(), "audit"),
      external_cache_root(),
      memory_root(),
      Path.join(memory_root(), "notes"),
      Path.join(memory_root(), "preferences"),
      Path.join(memory_root(), "traces"),
      Path.join(memory_root(), "skills"),
      workspace_root(),
      workspace_canvas_root(),
      workspace_ephemeral_root(),
      workspace_secrets_root(),
      themes_root(),
      theme_snippets_root(),
      Path.dirname(db_path()),
      skills_root(),
      cache_root(),
      Path.join(cache_root(), "skills"),
      online_skill_sources_root(),
      tmp_root()
    ]
    |> Enum.each(&File.mkdir_p!/1)

    home
  end

  @doc "Return the Settings Central root."
  @spec settings_root() :: String.t()
  def settings_root do
    first_path(
      [
        app_root(AllbertAssist.Settings),
        configured(:settings_root),
        env_path("ALLBERT_SETTINGS_ROOT")
      ],
      Path.join(home(), "settings")
    )
  end

  @doc "Return the markdown memory root."
  @spec memory_root() :: String.t()
  def memory_root do
    first_path(
      [
        app_root(AllbertAssist.Memory),
        configured(:memory_root),
        env_path("ALLBERT_MEMORY_ROOT")
      ],
      Path.join(home(), "memory")
    )
  end

  @doc "Return the archived deleted-memory root."
  @spec memory_deleted_root() :: String.t()
  def memory_deleted_root do
    Path.join(memory_root(), "deleted")
  end

  @doc "Return the durable confirmation request root."
  @spec confirmations_root() :: String.t()
  def confirmations_root do
    first_path(
      [app_root(AllbertAssist.Confirmations), configured(:confirmations_root)],
      Path.join(home(), "confirmations")
    )
  end

  @doc "Return the local execution runtime root."
  @spec execution_root() :: String.t()
  def execution_root do
    first_path([app_root(AllbertAssist.Execution.Audit)], Path.join(home(), "execution"))
  end

  @doc "Return the package installation execution root."
  @spec package_installs_root() :: String.t()
  def package_installs_root do
    first_path(
      [configured(:package_installs_root)],
      Path.join(execution_root(), "package-installs")
    )
  end

  @doc "Return the v0.36 Elixir/OTP sandbox root."
  @spec sandbox_root() :: String.t()
  def sandbox_root do
    first_path([configured(:sandbox_root)], Path.join(home(), "sandbox"))
  end

  @doc "Return the v0.36 sandbox bundle root."
  @spec sandbox_bundles_root() :: String.t()
  def sandbox_bundles_root, do: Path.join(sandbox_root(), "bundles")

  @doc "Return the v0.36 sandbox report root."
  @spec sandbox_reports_root() :: String.t()
  def sandbox_reports_root, do: Path.join(sandbox_root(), "reports")

  @doc "Return the v0.36 sandbox cache root."
  @spec sandbox_cache_root() :: String.t()
  def sandbox_cache_root, do: Path.join(sandbox_root(), "cache")

  @doc "Return the v0.36 sandbox audit root."
  @spec sandbox_audit_root() :: String.t()
  def sandbox_audit_root, do: Path.join(sandbox_root(), "audit")

  @doc "Return the v0.37 dynamic plugin root under Allbert Home."
  @spec dynamic_plugins_root() :: String.t()
  def dynamic_plugins_root do
    first_path([configured(:dynamic_plugins_root)], Path.join(home(), "dynamic_plugins"))
  end

  @doc "Return the v0.37 inert dynamic draft root."
  @spec dynamic_plugins_drafts_root() :: String.t()
  def dynamic_plugins_drafts_root, do: Path.join(dynamic_plugins_root(), "drafts")

  @doc "Return the v0.37 reviewed dynamic integration root."
  @spec dynamic_plugins_integrated_root() :: String.t()
  def dynamic_plugins_integrated_root, do: Path.join(dynamic_plugins_root(), "integrated")

  @doc "Return the external service adapter root."
  @spec external_root() :: String.t()
  def external_root do
    first_path([configured(:external_root)], Path.join(home(), "external"))
  end

  @doc "Return the external service response/cache root."
  @spec external_cache_root() :: String.t()
  def external_cache_root do
    first_path([configured(:external_cache_root)], Path.join(cache_root(), "external-services"))
  end

  @doc "Return the local SQLite database path."
  @spec db_path() :: String.t()
  def db_path do
    first_path(
      [configured(:db_path), env_path("DATABASE_PATH")],
      Path.join([home(), "db", "allbert.sqlite3"])
    )
  end

  @doc "Return the user-owned Agent Skills root."
  @spec skills_root() :: String.t()
  def skills_root do
    first_path([configured(:skills_root)], Path.join(home(), "skills"))
  end

  @doc "Return the Allbert cache root."
  @spec cache_root() :: String.t()
  def cache_root do
    first_path([configured(:cache_root)], Path.join(home(), "cache"))
  end

  @doc "Return the disabled imported-skill source cache root."
  @spec online_skill_sources_root() :: String.t()
  def online_skill_sources_root do
    first_path(
      [configured(:online_skill_sources_root)],
      Path.join([cache_root(), "skills", "_sources"])
    )
  end

  @doc "Return the Allbert temporary runtime root."
  @spec tmp_root() :: String.t()
  def tmp_root do
    first_path([configured(:tmp_root)], Path.join(home(), "tmp"))
  end

  @doc "Return the workspace substrate root."
  @spec workspace_root() :: String.t()
  def workspace_root do
    first_path([configured(:workspace_root)], Path.join(home(), "workspace"))
  end

  @doc "Return the workspace canvas body root."
  @spec workspace_canvas_root() :: String.t()
  def workspace_canvas_root, do: Path.join(workspace_root(), "canvas")

  @doc "Return the workspace ephemeral surface body root."
  @spec workspace_ephemeral_root() :: String.t()
  def workspace_ephemeral_root, do: Path.join(workspace_root(), "ephemeral")

  @doc "Return the workspace secret root."
  @spec workspace_secrets_root() :: String.t()
  def workspace_secrets_root, do: Path.join(workspace_root(), "secrets")

  @doc "Return the operator theme root."
  @spec themes_root() :: String.t()
  def themes_root do
    first_path([configured(:themes_root)], Path.join(home(), "themes"))
  end

  @doc "Return the operator CSS snippet root."
  @spec theme_snippets_root() :: String.t()
  def theme_snippets_root, do: Path.join(themes_root(), "snippets")

  defp first_path(paths, default) do
    Enum.find(paths, default, &is_binary/1)
  end

  defp configured(key) do
    @app
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
    |> expand_if_present()
  end

  defp app_root(module) do
    @app
    |> Application.get_env(module, [])
    |> Keyword.get(:root)
    |> expand_if_present()
  end

  defp expand_if_present(nil), do: nil
  defp expand_if_present(path) when is_binary(path), do: Path.expand(path)
  defp expand_if_present(_path), do: nil

  defp env_path(key) do
    key
    |> System.get_env()
    |> expand_if_present()
  end
end
