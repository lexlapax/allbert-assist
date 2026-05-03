defmodule AllbertAssist.Paths do
  @moduledoc """
  Resolves Allbert-owned local runtime paths.

  Allbert Home is the durable local root for settings, secrets, memory,
  databases, skills, caches, and temporary runtime files. Specific subsystem
  roots remain available as test, migration, compatibility, and operator escape
  hatches.
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
      external_root(),
      Path.join(external_root(), "audit"),
      external_cache_root(),
      memory_root(),
      Path.join(memory_root(), "notes"),
      Path.join(memory_root(), "preferences"),
      Path.join(memory_root(), "traces"),
      Path.join(memory_root(), "skills"),
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
