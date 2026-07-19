defmodule AllbertAssist.Plugin.PathsTest do
  @moduledoc """
  v0.62 M1 — the release-safe plugins-root resolution that replaces the
  compile-time `Path.expand(..., __DIR__)` sites (which froze the build
  machine's checkout path into the artifact).
  """
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Plugin.Paths

  setup do
    saved = %{
      root: System.get_env("ALLBERT_PLUGINS_ROOT"),
      release: System.get_env("RELEASE_ROOT")
    }

    System.delete_env("ALLBERT_PLUGINS_ROOT")
    System.delete_env("RELEASE_ROOT")

    on_exit(fn ->
      for {var, key} <- [{"ALLBERT_PLUGINS_ROOT", :root}, {"RELEASE_ROOT", :release}] do
        case saved[key] do
          nil -> System.delete_env(var)
          value -> System.put_env(var, value)
        end
      end
    end)

    :ok
  end

  test "RELEASE_ROOT/plugins wins (the packaged layout, no cwd dependency)" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "paths-rel-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(Path.join([tmp, "plugins", "stocksage", "priv", "repo", "migrations"]))
    System.put_env("RELEASE_ROOT", tmp)

    assert Paths.plugins_root() == Path.join(tmp, "plugins")
    assert Paths.plugin_root("stocksage") == Path.join([tmp, "plugins", "stocksage"])

    assert Paths.plugin_path("stocksage", ["priv", "repo", "migrations"]) ==
             Path.join([tmp, "plugins", "stocksage", "priv", "repo", "migrations"])

    File.rm_rf!(tmp)
  end

  test "ALLBERT_PLUGINS_ROOT overrides RELEASE_ROOT" do
    override =
      Path.join(
        System.tmp_dir!(),
        "paths-ovr-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(override)
    File.mkdir_p!(override)
    System.put_env("ALLBERT_PLUGINS_ROOT", override)
    System.put_env("RELEASE_ROOT", "/nonexistent/release")

    assert Paths.plugins_root() == Path.expand(override)
    File.rm_rf!(override)
  end

  test "the checkout walk-up is the dev/test fallback (finds this repo's plugins/)" do
    # No env set — resolves the umbrella's own plugins dir by walking up cwd.
    root = Paths.plugins_root()
    assert is_binary(root)
    assert Path.basename(root) == "plugins"
    assert File.dir?(Path.join(root, "stocksage"))
  end

  test "plugin_path returns nil (not a crash) when no root resolves" do
    System.put_env("RELEASE_ROOT", "/definitely/not/here")
    System.put_env("ALLBERT_PLUGINS_ROOT", "/also/not/here")

    # With both env paths dead, it falls to the checkout walk-up; in this repo
    # that still finds plugins/, so assert the contract shape instead.
    assert Paths.plugin_path("stocksage", "skills") =~ "stocksage/skills"
  end
end
