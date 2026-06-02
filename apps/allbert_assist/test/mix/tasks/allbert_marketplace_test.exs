defmodule Mix.Tasks.Allbert.MarketplaceTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Paths
  alias Mix.Tasks.Allbert.Marketplace, as: MarketplaceTask

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_env(original_env)
      Mix.Task.reenable("allbert.marketplace")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "seed catalog includes skill, template, and plugin_index entries with valid hashes",
       %{home: home} do
    assert {:ok, catalog} = Catalog.read(home: home)

    entries = catalog["entries"]
    assert Enum.map(entries, & &1["id"]) == all_seed_ids()
    assert Enum.map(entries, & &1["kind"]) == ["skill", "template", "plugin_index"]

    Enum.each(entries, fn entry ->
      assert {:ok, manifest} = Bundle.read_and_verify(entry, catalog["catalog_root"], home: home)
      assert manifest["bundle_hash"] == entry["bundle_hash"]
      assert manifest["verification"].bundle_hash == entry["bundle_hash"]
    end)
  end

  test "list supports kind filtering and lazy mirror writes", %{home: home} do
    mirror_path = Path.join(home, "marketplace/cache/index.json")
    refute File.exists?(mirror_path)

    output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["list", "--kind", "skill"])
      end)

    assert output =~ "allbert/research-helpers"
    refute output =~ "allbert/workspace-brief"
    refute output =~ "allbert/reviewed-plugin-sources"
    assert File.regular?(mirror_path)
  end

  test "show prints entry detail and bundle files" do
    output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["show", "allbert/workspace-brief"])
      end)

    assert output =~ "Entry: allbert/workspace-brief"
    assert output =~ "Kind: template"
    assert output =~ "Installable: true"
    assert output =~ "Install target:"
    assert output =~ "metadata.json sha256="
    assert output =~ "template.md sha256="
  end

  test "install, installed, verify, and rollback work end-to-end through the CLI", %{home: home} do
    install_output =
      capture_io(fn ->
        assert :ok =
                 MarketplaceTask.run([
                   "install",
                   "allbert/research-helpers",
                   "--version",
                   "1.0.0"
                 ])
      end)

    assert install_output =~ "allbert/research-helpers"
    assert install_output =~ "state=disabled_untrusted"
    assert File.regular?(Path.join(home, "marketplace/skills/allbert-research-helpers/SKILL.md"))

    installed_output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["installed"])
      end)

    assert installed_output =~ "allbert/research-helpers"
    assert installed_output =~ "state=disabled_untrusted"

    verify_output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["verify", "allbert/research-helpers"])
      end)

    assert verify_output =~ "allbert/research-helpers"
    assert verify_output =~ "status=ok"

    rollback_output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["rollback", "allbert/research-helpers"])
      end)

    assert rollback_output =~ "allbert/research-helpers version=1.0.0 rolled_back"
    refute File.exists?(Path.join(home, "marketplace/skills/allbert-research-helpers"))
  end

  test "plugin_index seed is browse-only at the CLI" do
    output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["show", "allbert/reviewed-plugin-sources"])
      end)

    assert output =~ "Entry: allbert/reviewed-plugin-sources"
    assert output =~ "Kind: plugin_index"
    assert output =~ "Installable: false"

    assert_raise Mix.Error, ~r/plugin_index_not_installable/, fn ->
      capture_io(fn ->
        MarketplaceTask.run(["install", "allbert/reviewed-plugin-sources"])
      end)
    end
  end

  test "mirror command eagerly writes the cached index", %{home: home} do
    mirror_path = Path.join(home, "marketplace/cache/index.json")
    refute File.exists?(mirror_path)

    output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["mirror"])
      end)

    assert output =~ "Marketplace index mirrored to #{mirror_path} entries=3"
    assert File.regular?(mirror_path)
  end

  test "doctor command prints the M5 live-check status" do
    output =
      capture_io(fn ->
        assert :ok = MarketplaceTask.run(["doctor"])
      end)

    assert output =~ "Marketplace doctor status=completed"
    assert output =~ "live_check_status=ok"
  end

  defp all_seed_ids do
    [
      "allbert/research-helpers",
      "allbert/workspace-brief",
      "allbert/reviewed-plugin-sources"
    ]
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-marketplace-task-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
