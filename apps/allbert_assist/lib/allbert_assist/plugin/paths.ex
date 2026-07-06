defmodule AllbertAssist.Plugin.Paths do
  @moduledoc """
  Release-safe resolution of the shipped-plugins root (v0.62 M1).

  The M0 spike proved the packaged layout: shipped plugin folders (manifest +
  `priv/` + `skills/`, no source) live in a `plugins/` directory **beside the
  release root**, and registering through it classifies them `:shipped`
  (home-root plugins are the declarative/trust-gated class and never register
  shipped code). Resolution order:

  1. `ALLBERT_PLUGINS_ROOT` — explicit operator override.
  2. `RELEASE_ROOT/plugins` — the packaged layout (`RELEASE_ROOT` is exported
     by the OTP release scripts).
  3. Checkout walk-up from `File.cwd!/0` — the dev/test layout (the pre-v0.62
     behavior, now the fallback instead of the only mechanism).

  Every path consumer that used a compile-time `Path.expand(..., __DIR__)`
  (which froze the *build machine's* checkout path into the artifact —
  Current Code State 4 in the v0.62 plan) resolves through this module at
  runtime instead.
  """

  @doc "The directory containing shipped plugin folders, or nil when absent."
  @spec plugins_root() :: String.t() | nil
  def plugins_root do
    env_root() || release_root() || checkout_root()
  end

  @doc """
  The directory that *contains* the `plugins/` folder (the discovery
  project-root notion). Falls back to cwd when no plugins root resolves.
  """
  @spec project_root() :: String.t()
  def project_root do
    case plugins_root() do
      nil -> Path.expand(File.cwd!())
      root -> Path.dirname(root)
    end
  end

  @doc "The root folder of one shipped plugin, or nil."
  @spec plugin_root(String.t()) :: String.t() | nil
  def plugin_root(plugin_id) when is_binary(plugin_id) do
    case plugins_root() do
      nil -> nil
      root -> Path.join(root, plugin_id)
    end
  end

  @doc """
  A path inside one shipped plugin (e.g. `plugin_path("stocksage",
  ["priv", "repo", "migrations"])`), or nil when the plugins root is absent.
  """
  @spec plugin_path(String.t(), [String.t()] | String.t()) :: String.t() | nil
  def plugin_path(plugin_id, segments) do
    case plugin_root(plugin_id) do
      nil -> nil
      root -> Path.join([root | List.wrap(segments)])
    end
  end

  defp env_root do
    with value when is_binary(value) and value != "" <-
           System.get_env("ALLBERT_PLUGINS_ROOT"),
         expanded = Path.expand(value),
         true <- File.dir?(expanded) do
      expanded
    else
      _other -> nil
    end
  end

  defp release_root do
    with value when is_binary(value) and value != "" <- System.get_env("RELEASE_ROOT"),
         candidate = Path.join(Path.expand(value), "plugins"),
         true <- File.dir?(candidate) do
      candidate
    else
      _other -> nil
    end
  end

  defp checkout_root do
    File.cwd!()
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn path, _acc ->
      cond do
        File.dir?(Path.join(path, "plugins")) -> {:halt, Path.join(path, "plugins")}
        Path.dirname(path) == path -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end
end
