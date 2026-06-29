defmodule AllbertAssist.Portability.ExportImportTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Portability.Export
  alias AllbertAssist.Portability.Import
  alias AllbertAssist.Portability.SecretReferences
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-portability-#{System.unique_integer([:positive])}"
      )

    home_a = Path.join(root, "home-a")
    home_b = Path.join(root, "home-b")
    evidence = Path.join(root, "evidence")

    Application.put_env(:allbert_assist, Paths, home: home_a)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    Paths.ensure_home!()
    File.mkdir_p!(home_b)
    File.mkdir_p!(evidence)

    {:ok, home_a: home_a, home_b: home_b, evidence: evidence}
  end

  test "export envelope is versioned, redacted, and includes fragment/file manifests", %{
    home_a: home_a
  } do
    seed_home!(home_a)

    assert {:ok, envelope} = Export.build(home: home_a)

    assert envelope["envelope_version"] == 1
    assert envelope["allbert_version"] =~ "."
    assert get_in(envelope, ["redaction", "secret_values_exported"]) == false
    assert get_in(envelope, ["settings", "version_contract", :status]) == :ok

    fragments = get_in(envelope, ["settings", "fragments"])
    assert Enum.any?(fragments, &(&1.fragment_id == "core:artifacts"))
    assert Enum.all?(fragments, &(&1.known_schema_version == 1))

    assert [
             %{"ref" => "secret://providers/openai/api_key", "status" => "missing"}
           ] = envelope["secret_references"]

    files = get_in(envelope, ["manifest", "home", "files"])
    assert Enum.any?(files, &(&1["path"] == "memory/notes/note.md" and &1["included"]))
    assert Enum.any?(files, &(&1["path"] == "settings/secrets.yml.enc" and not &1["included"]))
    assert Enum.any?(files, &(&1["path"] == "settings/.settings_key" and not &1["included"]))

    envelope_text = Jason.encode!(envelope)
    refute envelope_text =~ "sk-test"
    refute envelope_text =~ "raw-secret"
    refute envelope_text =~ "http://127.0.0.1:9999/v1"
    refute envelope_text =~ google_api_key_fixture()
    refute envelope_text =~ aws_access_key_fixture()
    assert envelope_text =~ generic_hex_fixture()
  end

  test "secret-reference helper returns refs only, never values" do
    settings = %{
      "providers" => %{
        "openai" => %{
          "api_key_ref" => "secret://providers/openai/api_key",
          "api_key" => "sk-test"
        }
      }
    }

    assert SecretReferences.collect(settings) == ["secret://providers/openai/api_key"]
    rows = SecretReferences.export_rows(settings)
    assert [%{"ref" => "secret://providers/openai/api_key"}] = rows
    refute inspect(rows) =~ "sk-test"
  end

  test "dry-run import validates envelope and leaves target Home byte-identical", %{
    home_a: home_a,
    home_b: home_b,
    evidence: evidence
  } do
    seed_home!(home_a)
    assert {:ok, envelope} = Export.build(home: home_a)
    envelope_path = Path.join(evidence, "home-a.envelope.json")
    File.write!(envelope_path, Jason.encode!(envelope, pretty: true))

    before = tree_digest(home_b)
    Application.put_env(:allbert_assist, Paths, home: home_b)
    assert {:ok, diagnostic} = Import.dry_run(envelope_path, target_home: home_b)
    after_digest = tree_digest(home_b)

    assert before == after_digest
    assert diagnostic["status"] == "ok"
    assert diagnostic["dry_run"] == true
    assert diagnostic["applied"] == false
    assert diagnostic["message"] =~ "applied nothing"
    assert get_in(diagnostic, ["inert_import_plan", "self_improvement_suggestions"]) == "inert"
    assert get_in(diagnostic, ["inert_import_plan", "voice_capture"]) == "not_armed"
    assert get_in(diagnostic, ["secret_references", "required"]) == 1
    assert get_in(diagnostic, ["secret_references", "missing"]) == 1

    assert [
             %{
               "ref" => "secret://providers/openai/api_key",
               "target_status" => "missing",
               "missing_in_target" => true
             }
           ] = get_in(diagnostic, ["secret_references", "refs"])

    refute inspect(diagnostic) =~ "sk-test"
  end

  test "dry-run import fails closed on forward fragment versions", %{
    home_a: home_a,
    home_b: home_b,
    evidence: evidence
  } do
    seed_home!(home_a)
    assert {:ok, envelope} = Export.build(home: home_a)

    forward =
      update_in(envelope, ["settings", "fragments"], fn [first | rest] ->
        [Map.put(first, :known_schema_version, 2) | rest]
      end)

    envelope_path = Path.join(evidence, "home-a-forward.envelope.json")
    File.write!(envelope_path, Jason.encode!(forward, pretty: true))

    before = tree_digest(home_b)
    Application.put_env(:allbert_assist, Paths, home: home_b)
    assert {:error, diagnostic} = Import.dry_run(envelope_path, target_home: home_b)
    assert before == tree_digest(home_b)
    assert diagnostic["status"] == "blocked"
    assert diagnostic["applied"] == false
    assert get_in(diagnostic, ["settings_version_contract", :counts, :forward]) == 1
    assert diagnostic["message"] =~ "refused"
  end

  defp seed_home!(home) do
    File.mkdir_p!(Path.join(home, "memory/notes"))
    File.write!(Path.join(home, "memory/notes/note.md"), "portable note\n")
    File.write!(Path.join(home, "settings/secrets.yml.enc"), "sk-test raw-secret\n")
    File.write!(Path.join(home, "settings/.settings_key"), "raw-secret\n")

    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "operator" => %{
                 "display_name" => "Audit #{google_api_key_fixture()} #{generic_hex_fixture()}"
               },
               "channels" => %{
                 "email" => %{"from_name" => "Audit #{aws_access_key_fixture()}"}
               },
               "voice" => %{
                 "local_runtime" => %{
                   "stt_model_alias" => "Audit local"
                 }
               },
               "providers" => %{
                 "openai" => %{
                   "enabled" => true,
                   "base_url" => "http://127.0.0.1:9999/v1",
                   "api_key_ref" => "secret://providers/openai/api_key"
                 }
               }
             })
  end

  defp tree_digest(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map_join("\n", fn path ->
      rel = Path.relative_to(path, root)
      "#{rel}:#{file_hash(path)}"
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp file_hash(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp google_api_key_fixture, do: "AI" <> "zaSyDUMMYSecretShapeForAudit59"
  defp aws_access_key_fixture, do: "AK" <> "IA1234567890ABCDEF"
  defp generic_hex_fixture, do: String.duplicate("a", 64)

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
