defmodule AllbertAssist.Marketplace.CatalogInstallTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Marketplace
  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Skills.Registry, as: Skills

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      restore_env(original_env)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "valid catalog parses, mirrors, and lists entries", %{home: home} do
    fixture = write_fixture(home: home)

    assert {:ok, catalog} = Catalog.read(index_path: fixture.index_path, home: home)
    assert catalog["schema_version"] == 1
    assert [entry] = catalog["entries"]
    assert entry["id"] == "allbert/research-helpers"
    assert entry["marketplace_uri"] == "marketplace://entry/allbert/research-helpers"
    assert File.regular?(Path.join(home, "marketplace/cache/index.json"))

    assert {:ok, [listed]} = Marketplace.list_entries(index_path: fixture.index_path, home: home)
    assert listed["id"] == "allbert/research-helpers"
  end

  test "catalog rejects unknown key, missing field, schema drift, hash mismatch, and traversal",
       %{home: home} do
    unknown = write_fixture(home: home, index_overrides: %{"extra" => true})
    assert {:error, diagnostic} = Catalog.read(index_path: unknown.index_path, home: home)
    assert diagnostic.code == :unknown_key
    assert diagnostic.pointer == "/extra"

    missing = write_fixture(home: home, entry_transform: &Map.delete(&1, "id"))
    assert {:error, diagnostic} = Catalog.read(index_path: missing.index_path, home: home)
    assert diagnostic.code == :missing_required_field
    assert diagnostic.pointer == "/entries/0/id"

    drift = write_fixture(home: home, index_overrides: %{"schema_version" => 2})
    assert {:error, diagnostic} = Catalog.read(index_path: drift.index_path, home: home)
    assert diagnostic.error_category == :catalog_schema_version_unsupported
    assert diagnostic.pointer == "/schema_version"

    mismatch =
      write_fixture(
        home: home,
        entry_overrides: %{"bundle_hash" => "sha256:" <> String.duplicate("b", 64)}
      )

    assert {:error, diagnostic} = Catalog.read(index_path: mismatch.index_path, home: home)
    assert diagnostic.error_category == :bundle_hash_mismatch
    assert is_binary(diagnostic.pointer)

    traversal = write_fixture(home: home, entry_overrides: %{"bundle_path" => "../outside"})
    assert {:error, diagnostic} = Catalog.read(index_path: traversal.index_path, home: home)
    assert diagnostic.code in [:invalid_bundle_path, :bundle_path_traversal]
    assert is_binary(diagnostic.pointer)
  end

  test "bundle manifest validates file hashes and recursive hash", %{home: home} do
    fixture = write_fixture(home: home)

    assert {:ok, entry} =
             Catalog.get_entry("allbert/research-helpers",
               index_path: fixture.index_path,
               home: home
             )

    assert {:ok, manifest} =
             Bundle.read_and_verify(entry, Path.dirname(fixture.index_path), home: home)

    assert manifest["bundle_hash"] == fixture.bundle_hash
    assert manifest["verification"].bundle_hash == fixture.bundle_hash
    assert Enum.map(manifest["verification"].files, & &1.path) == ["SKILL.md"]
  end

  test "install writes disabled/untrusted bundle and installed state, then rejects reinstalls",
       %{home: home} do
    fixture = write_fixture(home: home)

    assert {:ok, result} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: fixture.index_path,
               home: home
             )

    target = Path.join(home, "marketplace/skills/allbert-research-helpers")
    assert result.installed["install_target"] == target
    assert File.regular?(Path.join(target, "SKILL.md"))

    assert {:ok, [installed]} = Marketplace.list_installed(home: home)
    assert installed["entry_id"] == "allbert/research-helpers"
    assert installed["version"] == "1.0.0"
    assert installed["install_state"] == "disabled_untrusted"
    assert installed["bundle_hash"] == fixture.bundle_hash

    assert {:ok, diagnostics} =
             Skills.diagnostics(%{
               settings: %{
                 "marketplace_target_dir_skills" => Path.join(home, "marketplace/skills")
               }
             })

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.code == :marketplace_skill_disabled and
               diagnostic.source_scope == :marketplace_install
           end)

    assert {:error, diagnostic} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: fixture.index_path,
               home: home
             )

    assert diagnostic.error_category == :already_installed
  end

  test "install rejects a different version while another is installed", %{home: home} do
    v1 = write_fixture(home: home, version: "1.0.0")

    assert {:ok, _result} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: v1.index_path,
               home: home
             )

    v2 = write_fixture(home: home, version: "1.1.0", description: "Second version")

    assert {:error, diagnostic} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: v2.index_path,
               home: home
             )

    assert diagnostic.error_category == :version_conflict_requires_rollback
  end

  test "install rejects plugin_index without writes", %{home: home} do
    fixture = write_fixture(home: home, kind: "plugin_index", entry_id: "allbert/plugin-index")

    assert {:error, diagnostic} =
             Marketplace.install_bundle("allbert/plugin-index",
               index_path: fixture.index_path,
               home: home
             )

    assert diagnostic.error_category == :plugin_index_not_installable
    assert {:ok, []} = Marketplace.list_installed(home: home)
    refute File.exists?(Path.join(home, "marketplace/plugins"))
  end

  test "rollback removes install directory and installed state", %{home: home} do
    fixture = write_fixture(home: home)

    assert {:ok, result} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: fixture.index_path,
               home: home
             )

    assert File.dir?(result.installed["install_target"])

    assert {:ok, rollback} = Marketplace.rollback_install("allbert/research-helpers", home: home)
    refute File.exists?(rollback.removed["install_target"])
    assert {:ok, []} = Marketplace.list_installed(home: home)

    assert {:error, diagnostic} =
             Marketplace.rollback_install("allbert/research-helpers", home: home)

    assert diagnostic.error_category == :not_installed
  end

  defp write_fixture(opts) do
    _home = Keyword.fetch!(opts, :home)
    id = Keyword.get(opts, :entry_id, "allbert/research-helpers")
    version = Keyword.get(opts, :version, "1.0.0")
    kind = Keyword.get(opts, :kind, "skill")
    slug = String.replace(id, "/", "-")
    root = temp_path("catalog")
    bundle_rel = "bundles/#{slug}-#{version}"
    bundle_dir = Path.join(root, bundle_rel)
    File.mkdir_p!(bundle_dir)

    files =
      Keyword.get(opts, :files, %{"SKILL.md" => skill_body(slug, Keyword.get(opts, :description))})

    Enum.each(files, fn {path, body} ->
      full_path = Path.join(bundle_dir, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, body)
    end)

    {:ok, bundle_hash} = Bundle.compute_hash(bundle_dir)

    manifest =
      %{
        "schema_version" => 1,
        "id" => id,
        "version" => version,
        "kind" => kind,
        "files" =>
          Enum.map(files, fn {path, body} -> %{"path" => path, "sha256" => sha256(body)} end),
        "bundle_hash" => bundle_hash
      }
      |> maybe_put_install_fields(kind, slug)
      |> Map.merge(Keyword.get(opts, :manifest_overrides, %{}))

    File.write!(Path.join(bundle_dir, "bundle.json"), Jason.encode!(manifest, pretty: true))

    entry =
      %{
        "id" => id,
        "version" => version,
        "kind" => kind,
        "name" => "Research Helpers",
        "description" => Keyword.get(opts, :description, "Skill pack for research workflows."),
        "author" => "Allbert Maintainers",
        "license" => "MIT",
        "bundle_path" => bundle_rel,
        "bundle_hash" => bundle_hash,
        "provenance" => %{
          "scheme" => "shipped",
          "source_git_commit" => "abcdef1234567890",
          "review_date" => "2026-05-30"
        },
        "tags" => ["research", "skills"]
      }
      |> Map.merge(Keyword.get(opts, :entry_overrides, %{}))
      |> then(Keyword.get(opts, :entry_transform, & &1))

    index =
      %{
        "schema_version" => 1,
        "catalog_version" => "0.45.0",
        "source" => "shipped",
        "generated_at" => "2026-06-01T00:00:00Z",
        "source_git_commit" => "abcdef1234567890",
        "entries" => [entry]
      }
      |> Map.merge(Keyword.get(opts, :index_overrides, %{}))

    index_path = Path.join(root, "index.json")
    File.write!(index_path, Jason.encode!(index, pretty: true))

    %{index_path: index_path, bundle_hash: bundle_hash}
  end

  defp maybe_put_install_fields(manifest, "skill", slug) do
    Map.merge(manifest, %{
      "install_target" => "<ALLBERT_HOME>/marketplace/skills/#{slug}",
      "install_state" => "disabled_untrusted"
    })
  end

  defp maybe_put_install_fields(manifest, "template", slug) do
    Map.merge(manifest, %{
      "install_target" => "<ALLBERT_HOME>/marketplace/templates/#{slug}",
      "install_state" => "disabled_untrusted"
    })
  end

  defp maybe_put_install_fields(manifest, _kind, _slug), do: manifest

  defp skill_body(slug, description) do
    """
    ---
    name: #{slug}
    description: #{description || "#{slug} test skill."}
    ---

    ## Workflow

    Inspect only.
    """
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-marketplace-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
