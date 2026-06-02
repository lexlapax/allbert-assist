defmodule AllbertAssist.Security.V045MarketplaceEvalTest do
  use ExUnit.Case, async: false
  @moduletag :security_eval_serial
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Marketplace
  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Marketplace.Templates, as: MarketplaceTemplates
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.Registry, as: Skills

  @eval_ids [
    "marketplace-install-creates-disabled-state-001",
    "marketplace-install-grants-no-permission-001",
    "marketplace-skill-disabled-default-001",
    "marketplace-hash-mismatch-rejects-install-001",
    "marketplace-unknown-schema-version-rejects-001",
    "marketplace-index-unknown-key-rejects-001",
    "marketplace-bundle-manifest-missing-required-field-rejects-001",
    "marketplace-bundle-path-traversal-rejects-001",
    "marketplace-install-target-outside-allbert-home-rejects-001",
    "marketplace-workflow-yaml-never-installed-001",
    "marketplace-code-plugin-deny-001",
    "marketplace-template-metadata-no-execute-001",
    "marketplace-permission-grant-deny-001",
    "marketplace-provenance-hash-001",
    "marketplace-rollback-removes-install-001",
    "marketplace-installed-bundle-survives-upgrade-001",
    "marketplace-operator-modified-mirror-is-advisory-001",
    "marketplace-disabled-skill-cannot-execute-001",
    "marketplace-doctor-detects-orphan-install-001",
    "marketplace-doctor-detects-tampered-bundle-001"
  ]

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    File.mkdir_p!(home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home, context: %{actor: "local", channel: :test, surface: "v045_eval"}}
  end

  test "v0.45 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v045)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :marketplace_lite))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "install writes disabled/untrusted state and grants no permission", %{
    home: home
  } do
    assert_eval!("marketplace-install-creates-disabled-state-001")
    assert_eval!("marketplace-install-grants-no-permission-001")
    assert_eval!("marketplace-skill-disabled-default-001")

    assert {:ok, result} = Marketplace.install_bundle("allbert/research-helpers", home: home)
    assert result.installed["install_state"] == "disabled_untrusted"
    assert File.regular?(Path.join(result.installed["install_target"], "SKILL.md"))

    assert {:ok, []} = Grants.list()

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
  end

  test "catalog and bundle validation failures reject install without writes", %{home: home} do
    assert_eval!("marketplace-hash-mismatch-rejects-install-001")
    assert_eval!("marketplace-unknown-schema-version-rejects-001")
    assert_eval!("marketplace-index-unknown-key-rejects-001")
    assert_eval!("marketplace-bundle-manifest-missing-required-field-rejects-001")
    assert_eval!("marketplace-bundle-path-traversal-rejects-001")

    hash_mismatch =
      copy_catalog_fixture(home, "hash-mismatch")
      |> mutate_index_entry("allbert/research-helpers", fn entry ->
        Map.put(entry, "bundle_hash", "sha256:" <> String.duplicate("b", 64))
      end)

    assert {:error, %{error_category: :bundle_hash_mismatch}} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: hash_mismatch.index_path,
               home: home
             )

    schema_drift =
      copy_catalog_fixture(home, "schema-drift")
      |> mutate_index(fn index -> Map.put(index, "schema_version", 2) end)

    assert {:error, %{error_category: :catalog_schema_version_unsupported}} =
             Catalog.read(index_path: schema_drift.index_path, home: home)

    unknown_key =
      copy_catalog_fixture(home, "unknown-key")
      |> mutate_index(fn index -> Map.put(index, "extra", true) end)

    assert {:error, %{code: :unknown_key}} =
             Catalog.read(index_path: unknown_key.index_path, home: home)

    missing_required =
      copy_catalog_fixture(home, "manifest-missing")
      |> mutate_manifest("allbert-research-helpers-1.0.0", fn manifest ->
        Map.delete(manifest, "id")
      end)

    assert {:error, %{code: :missing_required_field}} =
             Catalog.read(index_path: missing_required.index_path, home: home)

    traversal =
      copy_catalog_fixture(home, "traversal")
      |> mutate_index_entry("allbert/research-helpers", fn entry ->
        Map.put(entry, "bundle_path", "../outside")
      end)

    assert {:error, %{code: code}} = Catalog.read(index_path: traversal.index_path, home: home)
    assert code in [:invalid_bundle_path, :bundle_path_traversal]

    refute File.exists?(Path.join(home, "marketplace/skills/allbert-research-helpers"))
  end

  test "install target scope, plugin_index, workflows, and permission gate fail closed", %{
    home: home,
    context: context
  } do
    assert_eval!("marketplace-install-target-outside-allbert-home-rejects-001")
    assert_eval!("marketplace-workflow-yaml-never-installed-001")
    assert_eval!("marketplace-code-plugin-deny-001")
    assert_eval!("marketplace-permission-grant-deny-001")

    outside =
      copy_catalog_fixture(home, "outside-target")
      |> mutate_manifest("allbert-research-helpers-1.0.0", fn manifest ->
        Map.put(manifest, "install_target", "/tmp/allbert-marketplace-escape")
      end)

    assert {:error, %{code: :install_target_outside_marketplace}} =
             Marketplace.install_bundle("allbert/research-helpers",
               index_path: outside.index_path,
               home: home
             )

    assert {:error, %{error_category: :plugin_index_not_installable}} =
             Marketplace.install_bundle("allbert/reviewed-plugin-sources", home: home)

    workflow_yaml =
      copy_catalog_fixture(home, "workflow-yaml")
      |> append_manifest_file(
        "allbert-research-helpers-1.0.0",
        "example-workflow.yaml",
        "schema_version: 1\nsteps: []\n"
      )

    assert {:error, %{code: :workflow_yaml_forward_pin_violation}} =
             Catalog.read(index_path: workflow_yaml.index_path, home: home)

    assert {:ok, _skill} = Marketplace.install_bundle("allbert/research-helpers", home: home)
    assert {:ok, _template} = Marketplace.install_bundle("allbert/workspace-brief", home: home)

    installed_files =
      home
      |> Path.join("marketplace/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    refute Enum.any?(installed_files, &String.ends_with?(&1, ".yaml"))
    refute Enum.any?(installed_files, &String.ends_with?(&1, ".yml"))

    denied_home = temp_path("denied-home")
    on_exit(fn -> File.rm_rf!(denied_home) end)

    Application.put_env(:allbert_assist, Paths, home: denied_home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(denied_home, "settings"))

    assert {:ok, _setting} =
             Settings.put("permissions.marketplace_install", "denied", %{audit?: false})

    assert {:ok, denied} =
             Runner.run(
               "install_marketplace_bundle",
               %{entry_id: "allbert/research-helpers"},
               context
             )

    assert denied.status == :denied
    refute File.exists?(Path.join(denied_home, "marketplace/skills/allbert-research-helpers"))
  end

  test "template metadata and provenance remain non-authority", %{home: home} do
    assert_eval!("marketplace-template-metadata-no-execute-001")
    assert_eval!("marketplace-provenance-hash-001")

    assert {:ok, catalog} = Catalog.read(home: home)

    assert Enum.all?(catalog["entries"], fn entry ->
             entry["provenance"]["scheme"] == "shipped" and
               match?(
                 {:ok, _manifest},
                 Bundle.read_and_verify(entry, catalog["catalog_root"], home: home)
               )
           end)

    before_patterns = AllbertAssist.Templates.list_patterns() |> Enum.map(& &1.id) |> MapSet.new()
    assert {:ok, _install} = Marketplace.install_bundle("allbert/workspace-brief", home: home)
    assert {:ok, [template]} = MarketplaceTemplates.list_installed(home: home)
    assert template.authority == "metadata_only"

    after_patterns = AllbertAssist.Templates.list_patterns() |> Enum.map(& &1.id) |> MapSet.new()
    assert after_patterns == before_patterns
    refute MapSet.member?(after_patterns, "marketplace_workspace_brief")
  end

  test "rollback, mirror, and cache authority preserve installed state", %{home: home} do
    assert_eval!("marketplace-rollback-removes-install-001")
    assert_eval!("marketplace-installed-bundle-survives-upgrade-001")
    assert_eval!("marketplace-operator-modified-mirror-is-advisory-001")
    assert_eval!("marketplace-disabled-skill-cannot-execute-001")

    assert {:ok, result} = Marketplace.install_bundle("allbert/research-helpers", home: home)
    target = result.installed["install_target"]
    marker = Path.join(target, "operator-marker.txt")
    File.write!(marker, "kept")

    assert {:ok, entries} = Marketplace.list_entries(home: home)
    assert Enum.any?(entries, &(&1["id"] == "allbert/research-helpers"))
    assert File.regular?(marker)

    mirror_path = Path.join(home, "marketplace/cache/index.json")
    File.write!(mirror_path, Jason.encode!(%{"schema_version" => 999, "entries" => []}))

    assert {:ok, entries} = Marketplace.list_entries(home: home)

    assert Enum.map(entries, & &1["id"]) == [
             "allbert/research-helpers",
             "allbert/workspace-brief",
             "allbert/reviewed-plugin-sources"
           ]

    assert {:ok, diagnostics} =
             Skills.diagnostics(%{
               settings: %{
                 "marketplace_target_dir_skills" => Path.join(home, "marketplace/skills")
               }
             })

    assert Enum.any?(diagnostics, &(&1.code == :marketplace_skill_disabled))

    assert {:ok, rollback} = Marketplace.rollback_install("allbert/research-helpers", home: home)
    refute File.exists?(rollback.removed["install_target"])
    assert {:ok, []} = Marketplace.list_installed(home: home)
  end

  test "doctor detects orphan and tampered installed bundles", %{home: home} do
    assert_eval!("marketplace-doctor-detects-orphan-install-001")
    assert_eval!("marketplace-doctor-detects-tampered-bundle-001")

    assert {:ok, orphan} = Marketplace.install_bundle("allbert/workspace-brief", home: home)
    File.rm_rf!(orphan.installed["install_target"])

    assert {:ok, doctor} = Marketplace.doctor(home: home)
    assert doctor.live_check_status == :degraded
    assert doctor.error_category == :orphan_install

    assert {:ok, _removed} = Marketplace.rollback_install("allbert/workspace-brief", home: home)
    assert {:ok, tampered} = Marketplace.install_bundle("allbert/workspace-brief", home: home)

    File.write!(Path.join(tampered.installed["install_target"], "template.md"), "\ntampered\n", [
      :append
    ])

    assert {:ok, doctor} = Marketplace.doctor(home: home)
    assert doctor.live_check_status == :degraded
    assert doctor.error_category == :installed_bundle_hash_mismatch
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp copy_catalog_fixture(home, name) do
    source =
      :allbert_assist
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("marketplace")

    target = Path.join(home, "catalog-fixtures/#{name}")
    File.mkdir_p!(Path.dirname(target))
    File.cp_r!(source, target)

    %{root: target, index_path: Path.join(target, "index.json")}
  end

  defp mutate_index(fixture, fun) do
    index = fixture.index_path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(fixture.index_path, Jason.encode!(index, pretty: true))
    fixture
  end

  defp mutate_index_entry(fixture, entry_id, fun) do
    mutate_index(fixture, fn index ->
      Map.update!(index, "entries", &mutate_entries(&1, entry_id, fun))
    end)
  end

  defp mutate_entries(entries, entry_id, fun) do
    Enum.map(entries, &mutate_entry(&1, entry_id, fun))
  end

  defp mutate_entry(%{"id" => id} = entry, entry_id, fun) when id == entry_id, do: fun.(entry)
  defp mutate_entry(entry, _entry_id, _fun), do: entry

  defp mutate_manifest(fixture, bundle_dir, fun) do
    path = Path.join([fixture.root, "bundles", bundle_dir, "bundle.json"])
    manifest = path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(path, Jason.encode!(manifest, pretty: true))
    fixture
  end

  defp append_manifest_file(fixture, bundle_dir, relative_path, body) do
    bundle_root = Path.join([fixture.root, "bundles", bundle_dir])
    File.write!(Path.join(bundle_root, relative_path), body)

    mutate_manifest(fixture, bundle_dir, fn manifest ->
      Map.update!(manifest, "files", fn files ->
        files ++ [%{"path" => relative_path, "sha256" => sha256(body)}]
      end)
    end)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-v045-marketplace-eval-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
