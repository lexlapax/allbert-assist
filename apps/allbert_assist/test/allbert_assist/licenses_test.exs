defmodule AllbertAssist.LicensesTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Licenses
  alias AllbertAssist.SecurityFixtures.AssertBinding

  test "catalog validation and union rendering are deterministic" do
    fixture = fixture!(["alpha", "beta"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    assert {:ok, first} = Licenses.repo_products(fixture.catalog, repo_root: fixture.repo)

    shuffled = %{
      fixture.catalog
      | "components" => Enum.reverse(fixture.catalog["components"]),
        "texts" => Enum.reverse(fixture.catalog["texts"])
    }

    assert {:ok, second} = Licenses.repo_products(shuffled, repo_root: fixture.repo)
    assert first.union == second.union
    assert first.catalog_json == second.catalog_json
    assert first.union =~ "Best-effort inventory"
    refute first.union =~ fixture.tmp
  end

  test "final manifests are byte-identical for shuffled release applications" do
    first = fixture!(["alpha", "beta"])
    second = fixture!(["alpha", "beta"])
    on_exit(fn -> File.rm_rf(first.tmp) end)
    on_exit(fn -> File.rm_rf(second.tmp) end)

    write_union!(first)
    write_union!(second)

    apps = [%{name: :alpha, version: "1.0.0"}, %{name: :beta, version: "1.0.0"}]
    target = target()

    assert {:ok, _result} =
             Licenses.finalize(first.catalog, apps, target,
               repo_root: first.repo,
               release_root: first.release
             )

    assert {:ok, _result} =
             Licenses.finalize(second.catalog, Enum.reverse(apps), target,
               repo_root: second.repo,
               release_root: second.release
             )

    assert File.read!(Path.join(first.release, "THIRD-PARTY-MANIFEST.json")) ==
             File.read!(Path.join(second.release, "THIRD-PARTY-MANIFEST.json"))

    AssertBinding.check!("v121-license-determinism-001", [
      :application_order_normalized,
      :manifest_bytes_identical,
      :host_time_absent
    ])
  end

  test "managed seams fail closed but arbitrary bytes only produce a bounded warning" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    File.write!(Path.join(fixture.release, "arbitrary-unclassified.bin"), "opaque")

    assert {:ok, %{manifest: manifest}} = finalize(fixture)
    assert length(manifest["warnings"]) == 1
    assert hd(manifest["warnings"]) =~ "not recursively attributed"

    missing = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(missing.tmp) end)
    write_union!(missing)
    File.rm!(Path.join([missing.release, "lib", "alpha-1.0.0", "priv", "payload.bin"]))

    assert {:error, %{code: :managed_path_missing}} = finalize(missing)

    AssertBinding.check!("v121-license-known-seam-001", [
      :known_seam_fails_closed,
      :unknown_byte_bounded,
      :no_completeness_claim
    ])
  end

  test "observed managed components report target truth without becoming required" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    observed = %{
      "id" => "observed-native-library",
      "name" => "observed native library",
      "kind" => "managed_file",
      "license_expression" => "MIT",
      "bundled" => true,
      "presence" => "observed",
      "text_ids" => ["MIT"],
      "file" => %{"path" => "optional-native.bin"}
    }

    catalog = %{
      fixture.catalog
      | "components" => fixture.catalog["components"] ++ [observed]
    }

    {:ok, products} = Licenses.repo_products(catalog, repo_root: fixture.repo)
    File.write!(Path.join(fixture.repo, "THIRD-PARTY-LICENSES.md"), products.union)

    assert {:ok, %{manifest: absent_manifest} = absent_result} =
             Licenses.finalize(catalog, [%{name: :alpha}], target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    absent = Enum.find(absent_manifest["components"], &(&1["id"] == observed["id"]))
    assert absent["bundled"] == false
    assert absent["sha256"] == nil

    assert {:ok, _verified} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: absent_result.manifest_sha256
             )

    File.write!(Path.join(fixture.release, "optional-native.bin"), "native\n")

    assert {:ok, %{manifest: present_manifest} = present_result} =
             Licenses.finalize(catalog, [%{name: :alpha}], target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    present = Enum.find(present_manifest["components"], &(&1["id"] == observed["id"]))
    assert present["bundled"] == true
    assert present["sha256"] == digest("native\n")

    assert {:ok, _verified} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: present_result.manifest_sha256
             )
  end

  test "observed managed absence rejects a symlinked parent during finalize and verify" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    observed = %{
      "id" => "observed-native-library",
      "name" => "observed native library",
      "kind" => "managed_file",
      "license_expression" => "MIT",
      "bundled" => true,
      "presence" => "observed",
      "text_ids" => ["MIT"],
      "file" => %{"path" => "optional/observed.bin"}
    }

    catalog = %{
      fixture.catalog
      | "components" => fixture.catalog["components"] ++ [observed]
    }

    {:ok, products} = Licenses.repo_products(catalog, repo_root: fixture.repo)
    File.write!(Path.join(fixture.repo, "THIRD-PARTY-LICENSES.md"), products.union)
    File.mkdir_p!(Path.join(fixture.release, "optional"))

    assert {:ok, finalized} =
             Licenses.finalize(catalog, [%{name: :alpha}], target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    outside = Path.join(fixture.tmp, "outside-observed")
    File.mkdir_p!(outside)
    File.rm_rf!(Path.join(fixture.release, "optional"))
    File.ln_s!(outside, Path.join(fixture.release, "optional"))

    assert {:error, %{code: verification_code}} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: finalized.manifest_sha256
             )

    assert verification_code in [:payload_mutated, :unsafe_release_path]

    assert {:error, %{code: :unsafe_release_path}} =
             Licenses.finalize(catalog, [%{name: :alpha}], target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )
  end

  test "unknown and missing BEAM applications fail with stable errors" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)

    unknown_ebin = Path.join([fixture.release, "lib", "unknown-1.0.0", "ebin"])
    File.mkdir_p!(unknown_ebin)
    File.write!(Path.join(unknown_ebin, "unknown.app"), app_spec("unknown"))

    assert {:error, %{code: :unknown_application, message: message}} =
             Licenses.finalize(
               fixture.catalog,
               [%{name: :alpha}],
               target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    assert message =~ "unknown"

    File.rm_rf!(Path.join([fixture.release, "lib", "unknown-1.0.0"]))
    File.rm_rf!(Path.join([fixture.release, "lib", "alpha-1.0.0"]))

    assert {:error, %{code: :missing_application}} =
             Licenses.finalize(
               fixture.catalog,
               [],
               target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )
  end

  test "text and pinned managed-payload drift fail closed" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    File.write!(Path.join(fixture.repo, "MIT.txt"), "changed\n")

    assert {:error, %{code: :license_text_digest_mismatch}} =
             Licenses.validate_catalog(fixture.catalog, repo_root: fixture.repo)

    pinned = fixture!(["alpha"], pin_payload?: true)
    on_exit(fn -> File.rm_rf(pinned.tmp) end)
    write_union!(pinned)
    File.write!(Path.join([pinned.release, "lib", "alpha-1.0.0", "priv", "payload.bin"]), "drift")

    assert {:error, %{code: :managed_digest_mismatch}} = finalize(pinned)
  end

  test "reviewed dependency input drift requires explicit catalog disposition" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    File.write!(Path.join(fixture.repo, "review.lock"), "changed\n")

    assert {:error, %{code: :reviewed_input_drift}} =
             Licenses.validate_catalog(fixture.catalog, repo_root: fixture.repo)
  end

  test "bundled components require text and declared source availability" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    [beam | rest] = fixture.catalog["components"]
    missing_text = [%{beam | "text_ids" => []} | rest]

    assert {:error, %{code: :missing_required_text}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "components" => missing_text},
               repo_root: fixture.repo
             )

    source_required =
      Enum.map(fixture.catalog["components"], fn
        %{"id" => "managed-alpha-payload"} = component ->
          Map.put(component, "source_required", true)

        component ->
          component
      end)

    assert {:error, %{code: :source_unavailable}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "components" => source_required},
               repo_root: fixture.repo
             )
  end

  test "license expressions and the MPL exception are closed and exact-file scoped" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    [beam | rest] = fixture.catalog["components"]
    unapproved = [%{beam | "license_expression" => "GPL-3.0-only"} | rest]

    assert {:error, %{code: :unapproved_license}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "components" => unapproved},
               repo_root: fixture.repo
             )

    bad_texts = [%{beam | "license_expression" => "NOASSERTION"} | rest]

    assert {:error, %{code: :license_text_set_mismatch}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "components" => bad_texts},
               repo_root: fixture.repo
             )

    wrong_class = [%{beam | "license_expression" => "Apache-2.0"} | rest]

    assert {:error, %{code: :license_text_set_mismatch}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "components" => wrong_class},
               repo_root: fixture.repo
             )

    [mit_text] = fixture.catalog["texts"]

    bad_content_id =
      Map.put(mit_text, "id", "LicenseText-00000000000000000000")

    assert {:error, %{code: :invalid_text_id}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "texts" => [bad_content_id]},
               repo_root: fixture.repo
             )

    illicit_mpl = %{beam | "license_expression" => "MPL-2.0", "text_ids" => ["MPL-2.0"]}
    mpl_text = %{mit_text | "id" => "MPL-2.0", "license_id" => "MPL-2.0"}

    assert {:error, %{code: :unapproved_license}} =
             Licenses.validate_catalog(
               %{
                 fixture.catalog
                 | "components" => [illicit_mpl | rest],
                   "texts" => [mit_text, mpl_text]
               },
               repo_root: fixture.repo
             )
  end

  test "the reviewed Castore CA exception binds one file, text, and immutable source" do
    assert {:ok, catalog} = Licenses.load_catalog()
    component = Enum.find(catalog["components"], &(&1["id"] == "castore-mozilla-ca"))
    text = Enum.find(catalog["texts"], &(&1["id"] == "MPL-2.0"))

    assert component["kind"] == "managed_file"
    assert component["license_expression"] == "MPL-2.0"
    assert component["text_ids"] == ["MPL-2.0"]
    assert component["file"]["application"] == "castore"
    assert component["file"]["relative_path"] == "priv/cacerts.pem"
    assert component["provenance"]["scope"] =~ "Only lib/castore-*/priv/cacerts.pem"
    assert component["source"]["immutable_url"] =~ ~r|/mozilla-firefox/firefox/[0-9a-f]{40}/|
    assert component["source"]["sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert component["source"]["converter_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert text["sha256"] =~ ~r/^[0-9a-f]{64}$/

    AssertBinding.check!("v121-license-castore-001", [
      :ca_payload_digest_bound,
      :mpl_text_bound,
      :exception_exact_file_scoped
    ])
  end

  test "schema v1 rejects an unimplemented source companion mode" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)

    components =
      Enum.map(fixture.catalog["components"], fn
        %{"id" => "managed-alpha-payload"} = component ->
          component
          |> Map.put("source_required", true)
          |> Map.put("source", %{
            "companion" => %{"path" => "source.txt", "sha256" => String.duplicate("0", 64)}
          })

        component ->
          component
      end)

    assert {:error, %{code: :unsupported_source_mode}} =
             Licenses.validate_catalog(
               %{fixture.catalog | "components" => components},
               repo_root: fixture.repo
             )
  end

  test "a declared external runtime may not appear in the artifact" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    File.mkdir_p!(Path.join(fixture.release, "external/node_modules"))

    assert {:error, %{code: :external_runtime_bundled}} = finalize(fixture)
  end

  test "target metadata and target-conditioned paths cannot mislabel the artifact" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)

    assert {:error, %{code: :invalid_target}} =
             Licenses.finalize(fixture.catalog, [%{name: :alpha}], %{triple: "linux-x64"},
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    other_triple = other_target_triple()

    assert {:error, %{code: :target_runtime_mismatch}} =
             Licenses.finalize(
               fixture.catalog,
               [%{name: :alpha}],
               Map.put(target(), "triple", other_triple),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    assert {:error, %{code: :target_runtime_mismatch}} =
             Licenses.finalize(
               fixture.catalog,
               [%{name: :alpha}],
               Map.put(target(), "otp_version", "0.0.0"),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    inactive_component = %{
      "id" => "inactive-only",
      "name" => "inactive-only fixture",
      "kind" => "managed_file",
      "license_expression" => "MIT",
      "bundled" => true,
      "text_ids" => ["MIT"],
      "targets" => [other_triple],
      "file" => %{"path" => "inactive-only.bin"}
    }

    catalog = %{
      fixture.catalog
      | "components" => fixture.catalog["components"] ++ [inactive_component]
    }

    File.write!(Path.join(fixture.release, "inactive-only.bin"), "wrong target\n")
    {:ok, products} = Licenses.repo_products(catalog, repo_root: fixture.repo)
    File.write!(Path.join(fixture.repo, "THIRD-PARTY-LICENSES.md"), products.union)

    assert {:error, %{code: :unexpected_target_component}} =
             Licenses.finalize(catalog, [%{name: :alpha}], target(),
               repo_root: fixture.repo,
               release_root: fixture.release
             )

    duplicate_targets = %{inactive_component | "targets" => [other_triple, other_triple]}

    assert {:error, %{code: :duplicate_target}} =
             Licenses.validate_catalog(
               %{
                 fixture.catalog
                 | "components" => fixture.catalog["components"] ++ [duplicate_targets]
               },
               repo_root: fixture.repo
             )

    unsupported_target = %{inactive_component | "targets" => ["linux-riscv64"]}

    assert {:error, %{code: :invalid_schema}} =
             Licenses.validate_catalog(
               %{
                 fixture.catalog
                 | "components" => fixture.catalog["components"] ++ [unsupported_target]
               },
               repo_root: fixture.repo
             )
  end

  test "managed files may not escape through symlinks" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    managed = Path.join([fixture.release, "lib", "alpha-1.0.0", "priv", "payload.bin"])
    outside = Path.join(fixture.tmp, "outside.bin")
    File.write!(outside, "managed")
    File.rm!(managed)
    File.ln_s!(outside, managed)

    assert {:error, %{code: :unsafe_release_path}} = finalize(fixture)
  end

  test "viewer renders summary, list, show, notices, and canonical JSON without starting apps" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    assert {:ok, _result} = finalize(fixture)

    started_before = Application.started_applications()

    assert {:ok, %{output: summary}} = Licenses.view([], release_root: fixture.release)
    assert summary =~ "Known components: 3"
    assert summary =~ "Best-effort inventory"

    assert {:ok, %{output: list}} = Licenses.view(["list"], release_root: fixture.release)
    assert list =~ "beam-alpha\tMIT\tbundled"
    assert list =~ "external-node\tNOASSERTION\texternal"

    assert {:ok, %{output: shown}} =
             Licenses.view(["show", "beam-alpha"], release_root: fixture.release)

    assert shown =~ "Component: beam-alpha"
    assert shown =~ "Permission is hereby granted"

    assert {:ok, %{output: notices}} =
             Licenses.view(["notices"], release_root: fixture.release)

    assert notices =~ "Fixture notice"
    assert notices =~ "Third-Party Licenses And Provenance"

    assert {:ok, %{output: json, format: :json}} =
             Licenses.view(["--json"], release_root: fixture.release)

    assert {:ok, %{"schema_version" => 1}} = Jason.decode(json)
    assert Application.started_applications() == started_before

    AssertBinding.check!("v121-license-viewer-001", [
      :packaged_metadata_read,
      :viewer_modes_rendered,
      :runtime_not_started
    ])
  end

  test "viewer returns stable diagnostics for bad arguments and corrupt metadata" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    assert {:ok, _result} = finalize(fixture)

    assert {:error, %{code: :invalid_arguments, exit_status: 2, message: usage}} =
             Licenses.view(["wat"], release_root: fixture.release)

    assert usage =~ "Usage: allbert licenses"

    File.write!(Path.join(fixture.release, "THIRD-PARTY-MANIFEST.json"), "not-json\n")

    assert {:error, %{code: :manifest_invalid, exit_status: 3, message: message}} =
             Licenses.view([], release_root: fixture.release)

    assert message =~ "not valid JSON"
  end

  test "verification catches every post-finalizer payload mutation" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    assert {:ok, result} = finalize(fixture)

    assert {:ok, _result} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: result.manifest_sha256
             )

    File.write!(Path.join(fixture.release, "payload.txt"), "mutated\n")

    assert {:error, %{code: :payload_mutated}} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: result.manifest_sha256
             )
  end

  test "verification binds the manifest and file modes" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    assert {:ok, result} = finalize(fixture)

    manifest_path = Path.join(fixture.release, "THIRD-PARTY-MANIFEST.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!() |> Map.put("components", [])
    File.write!(manifest_path, Licenses.canonical_json(manifest))

    assert {:error, %{code: :manifest_digest_mismatch}} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: result.manifest_sha256
             )

    assert {:error, %{code: :manifest_invalid}} =
             Licenses.view([], release_root: fixture.release)

    assert {:ok, _result} = finalize(fixture)
    File.chmod!(Path.join(fixture.release, "NOTICE"), 0o600)

    assert {:error, %{code: :generated_file_corrupt}} =
             Licenses.view([], release_root: fixture.release)

    assert {:ok, result} = finalize(fixture)
    payload = Path.join(fixture.release, "payload.txt")
    File.chmod!(payload, 0o600)

    assert {:error, %{code: :payload_mutated}} =
             Licenses.verify(
               release_root: fixture.release,
               manifest_sha256: result.manifest_sha256
             )
  end

  test "finalization owns an exact contained licenses tree" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    outside = Path.join(fixture.tmp, "outside-licenses")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel"), "keep\n")
    File.ln_s!(outside, Path.join(fixture.release, "licenses"))

    assert {:ok, _result} = finalize(fixture)
    assert File.read!(Path.join(outside, "sentinel")) == "keep\n"

    assert {:ok, %File.Stat{type: :directory}} =
             File.lstat(Path.join(fixture.release, "licenses"))

    stale = Path.join(fixture.release, "licenses/texts/stale.txt")
    File.write!(stale, "stale\n")

    assert {:error, %{code: :generated_file_corrupt}} =
             Licenses.view([], release_root: fixture.release)

    assert {:ok, _result} = finalize(fixture)
    refute File.exists?(stale)
  end

  test "viewer bounds every packaged evidence read" do
    fixture = fixture!(["alpha"])
    on_exit(fn -> File.rm_rf(fixture.tmp) end)
    write_union!(fixture)
    assert {:ok, _result} = finalize(fixture)
    File.write!(Path.join(fixture.release, "NOTICE"), :binary.copy("x", 5_000_001))

    assert {:error, %{code: :metadata_too_large, exit_status: 3}} =
             Licenses.view(["notices"], release_root: fixture.release)
  end

  defp fixture!(apps, opts \\ []) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "allbert-license-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(tmp, "repo")
    release = Path.join(tmp, "release")
    File.mkdir_p!(repo)
    File.mkdir_p!(release)

    text = """
    MIT License

    Permission is hereby granted, free of charge, to any person obtaining a copy.
    """

    File.write!(Path.join(repo, "MIT.txt"), text)
    File.write!(Path.join(repo, "review.lock"), "reviewed\n")
    File.write!(Path.join(repo, "LICENSE"), text)
    File.write!(Path.join(repo, "NOTICE"), "Fixture notice\n")
    File.write!(Path.join(release, "payload.txt"), "payload\n")
    File.mkdir_p!(Path.join(release, "erts-#{target()["erts_version"]}"))

    app_components =
      Enum.map(apps, fn app ->
        app_root = Path.join([release, "lib", "#{app}-1.0.0"])
        File.mkdir_p!(Path.join(app_root, "ebin"))
        File.mkdir_p!(Path.join(app_root, "priv"))
        File.write!(Path.join([app_root, "ebin", "#{app}.app"]), app_spec(app))
        File.write!(Path.join(app_root, "priv/payload.bin"), "managed")

        %{
          "id" => "beam-#{app}",
          "name" => app,
          "kind" => "beam_app",
          "application" => app,
          "license_expression" => "MIT",
          "bundled" => true,
          "text_ids" => ["MIT"]
        }
      end)

    managed = %{
      "id" => "managed-alpha-payload",
      "name" => "managed fixture payload",
      "kind" => "managed_file",
      "license_expression" => "MIT",
      "bundled" => true,
      "text_ids" => ["MIT"],
      "file" => %{
        "application" => hd(apps),
        "relative_path" => "priv/payload.bin"
      }
    }

    managed =
      if opts[:pin_payload?] do
        put_in(managed, ["file", "sha256"], digest("managed"))
        |> put_in(["file", "digest_required"], true)
      else
        managed
      end

    external = %{
      "id" => "external-node",
      "name" => "Node fixture",
      "kind" => "external",
      "license_expression" => "NOASSERTION",
      "bundled" => false,
      "text_ids" => [],
      "forbidden_paths" => ["external/node_modules"]
    }

    catalog = %{
      "schema_version" => 1,
      "claim" => "Best-effort inventory of known shipped components.",
      "reviewed_inputs" => [
        %{"id" => "fixture-lock", "path" => "review.lock", "sha256" => digest("reviewed\n")}
      ],
      "texts" => [
        %{
          "id" => "MIT",
          "license_id" => "MIT",
          "path" => "MIT.txt",
          "sha256" => digest(text)
        }
      ],
      "components" => app_components ++ [managed, external]
    }

    %{tmp: tmp, repo: repo, release: release, catalog: catalog, apps: apps}
  end

  defp write_union!(fixture) do
    {:ok, products} = Licenses.repo_products(fixture.catalog, repo_root: fixture.repo)
    File.write!(Path.join(fixture.repo, "THIRD-PARTY-LICENSES.md"), products.union)
  end

  defp finalize(fixture) do
    actual = Enum.map(fixture.apps, &%{name: &1, version: "1.0.0"})

    Licenses.finalize(fixture.catalog, actual, target(),
      repo_root: fixture.repo,
      release_root: fixture.release
    )
  end

  defp target do
    {:ok, target} = Licenses.build_target()
    target
  end

  defp other_target_triple do
    Enum.find(~w(linux-x64 linux-arm64 macos-arm64), &(&1 != target()["triple"]))
  end

  defp app_spec(app), do: "{application, #{app}, [{vsn, \"1.0.0\"}]}.\n"

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
