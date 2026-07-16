defmodule AllbertAssist.MarketplaceTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Marketplace.Doctor, as: MarketplaceDoctor
  alias AllbertAssist.Actions.Marketplace.InspectEntry, as: MarketplaceInspectEntry
  alias AllbertAssist.Actions.Marketplace.InstallBundle, as: MarketplaceInstallBundle
  alias AllbertAssist.Actions.Marketplace.ListEntries, as: MarketplaceListEntries
  alias AllbertAssist.Actions.Marketplace.ListInstalled, as: MarketplaceListInstalled
  alias AllbertAssist.Actions.Marketplace.RollbackInstall, as: MarketplaceRollbackInstall
  alias AllbertAssist.Actions.Marketplace.VerifyBundleHash, as: MarketplaceVerifyBundleHash
  alias AllbertAssist.Marketplace
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")
    File.mkdir_p!(home)

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "doctor passes on clean catalog and clean template install", %{home: home} do
    assert {:ok, install} = Marketplace.install_bundle("allbert/workspace-brief", home: home)
    assert File.regular?(Path.join(install.installed["install_target"], "template.md"))

    assert {:ok, doctor} = Marketplace.doctor(home: home)

    assert doctor.endpoint_kind == :local_endpoint
    assert doctor.credential_ok == nil
    assert doctor.endpoint_ok
    assert doctor.model_available == :unknown
    assert doctor.redacted_host == "local"
    assert doctor.live_check_status == :ok
    assert doctor.error_category == :none
    assert doctor.diagnostics == []
    assert doctor.catalog.entry_count == 3
    assert doctor.installed.template_count == 1
    assert doctor.checks.schema_version == :ok
    assert doctor.checks.catalog == :ok
    assert doctor.checks.installed_bundles == :ok
    assert is_binary(doctor.last_verified_at)

    assert {:ok, persisted} =
             home
             |> Path.join("marketplace/doctor/state.json")
             |> File.read!()
             |> Jason.decode(keys: :atoms)

    assert persisted.live_check_status == "ok"
    assert persisted.last_verified_at == doctor.last_verified_at
  end

  test "doctor action returns the ADR 0047 marketplace envelope", %{home: home} do
    assert {:ok, _install} = Marketplace.install_bundle("allbert/workspace-brief", home: home)

    assert {:ok, response} =
             MarketplaceDoctor.run(%{}, %{actor: "local", channel: :test, surface: "test"})

    assert response.status == :completed
    assert response.doctor.live_check_status == :ok
    assert response.result == response.doctor
    assert response.diagnostics == []
    assert [%{name: "marketplace_doctor", status: :completed}] = response.actions
  end

  test "marketplace.enabled=false disables every marketplace action", %{home: home} do
    assert {:ok, _setting} = Settings.put("marketplace.enabled", false, %{audit?: false})

    actions = [
      {MarketplaceListEntries, %{}},
      {MarketplaceInspectEntry, %{entry_id: "allbert/research-helpers"}},
      {MarketplaceListInstalled, %{}},
      {MarketplaceVerifyBundleHash, %{entry_id: "allbert/research-helpers"}},
      {MarketplaceDoctor, %{}},
      {MarketplaceInstallBundle, %{entry_id: "allbert/research-helpers"}},
      {MarketplaceRollbackInstall, %{entry_id: "allbert/research-helpers"}}
    ]

    Enum.each(actions, fn {action, params} ->
      assert {:ok, response} = action.run(params, %{actor: "local", channel: :test})
      assert response.status == :unavailable
      assert response.error.error_category == :marketplace_disabled

      assert [%{code: :marketplace_disabled, pointer: "/marketplace/enabled"}] =
               response.diagnostics
    end)

    refute File.exists?(Path.join(home, "marketplace/skills/allbert-research-helpers"))
  end

  test "doctor detects index parse errors", %{home: home} do
    index_path = Path.join(home, "broken-index.json")
    File.write!(index_path, "{not json")

    assert {:ok, doctor} = Marketplace.doctor(index_path: index_path, home: home)

    assert doctor.endpoint_ok == false
    assert doctor.live_check_status == :failed
    assert doctor.error_category == :catalog_invalid
    assert [%{code: :invalid_json, pointer: "/"}] = doctor.diagnostics
  end

  test "doctor detects catalog bundle hash mismatch", %{home: home} do
    fixture = copy_catalog_fixture(home)
    index = fixture.index_path |> File.read!() |> Jason.decode!()

    index =
      update_in(index, ["entries"], fn entries ->
        Enum.map(entries, fn
          %{"id" => "allbert/research-helpers"} = entry ->
            Map.put(entry, "bundle_hash", "sha256:" <> String.duplicate("b", 64))

          entry ->
            entry
        end)
      end)

    File.write!(fixture.index_path, Jason.encode!(index, pretty: true))

    assert {:ok, doctor} = Marketplace.doctor(index_path: fixture.index_path, home: home)

    assert doctor.live_check_status == :failed
    assert doctor.error_category == :bundle_hash_mismatch
    assert [%{code: :bundle_hash_mismatch}] = doctor.diagnostics
  end

  test "doctor detects installed bundle tampering", %{home: home} do
    assert {:ok, install} = Marketplace.install_bundle("allbert/workspace-brief", home: home)

    File.write!(Path.join(install.installed["install_target"], "template.md"), "\ntampered\n", [
      :append
    ])

    assert {:ok, doctor} = Marketplace.doctor(home: home)

    assert doctor.live_check_status == :degraded
    assert doctor.error_category == :installed_bundle_hash_mismatch

    assert [
             %{
               code: :installed_bundle_hash_mismatch,
               details: %{entry_id: "allbert/workspace-brief"}
             }
           ] = doctor.diagnostics
  end

  test "doctor detects orphan installs", %{home: home} do
    assert {:ok, install} = Marketplace.install_bundle("allbert/workspace-brief", home: home)
    File.rm_rf!(install.installed["install_target"])

    assert {:ok, doctor} = Marketplace.doctor(home: home)

    assert doctor.live_check_status == :degraded
    assert doctor.error_category == :orphan_install

    assert [%{code: :orphan_install, pointer: "/installed/0/install_target"}] =
             doctor.diagnostics
  end

  test "doctor detects marketplace schema_version drift", %{home: home} do
    assert {:ok, doctor} = Marketplace.doctor(home: home, expected_schema_version: 2)

    assert doctor.live_check_status == :failed
    assert doctor.error_category == :marketplace_schema_version_mismatch
    assert doctor.expected_schema_version == 2
    assert doctor.schema_version == 1
    assert [%{code: :marketplace_schema_version_mismatch}] = doctor.diagnostics
  end

  defp copy_catalog_fixture(home) do
    source =
      :allbert_assist
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("marketplace")

    target = Path.join(home, "fixture-marketplace")
    File.cp_r!(source, target)

    %{index_path: Path.join(target, "index.json")}
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-marketplace-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
