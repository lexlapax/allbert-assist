defmodule AllbertAssist.Pack.ReleaseAssemblyVerifierTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Pack.ReleaseAssemblyVerifier

  @version "1.3.2"
  @checkpoint "v14-m1a1"
  @repository "https://github.com/lexlapax/allbert-assist"
  @repo_root Path.expand("../../../../..", __DIR__)
  @support_applications ~w(kernel stdlib elixir logger crypto)a
  @allbert_applications ~w(allbert_kernel allbert_assist allbert_composition allbert_assist_web)a
  @release_applications @support_applications ++ @allbert_applications

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-release-assembly-verifier-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "verifies the exact packaged M1.a1 projection and emits one sealed marker", %{root: root} do
    fixture = write_release_fixture!(root)

    output =
      capture_io(fn ->
        result = verify_with_packaged_descriptors!(root)
        send(self(), {:verification_result, result})
      end)

    assert_receive {:verification_result, :ok}
    assert [line] = String.split(output, "\n", trim: true)
    assert "ALLBERT_RELEASE_ASSEMBLY_V1=" <> encoded = line
    marker = Jason.decode!(encoded)

    assert marker == %{
             "schema_version" => 1,
             "status" => "PASS",
             "checkpoint" => @checkpoint,
             "rel_sha256" => fixture.rel_sha256,
             "app_sha256" => %{
               "allbert_kernel" => fixture.app_sha256.allbert_kernel,
               "allbert_assist" => fixture.app_sha256.allbert_assist
             },
             "pack_projection_sha256" => expected_projection_sha256(fixture.app_sha256)
           }
  end

  test "rejects an effective Pack override before emitting a marker", %{root: root} do
    write_release_fixture!(root)
    previous = Application.fetch_env(:allbert_assist, :allbert_pack)

    on_exit(fn -> restore_env(:allbert_assist, :allbert_pack, previous) end)
    Application.put_env(:allbert_assist, :allbert_pack, AllbertAssist.Pack.Kernel)

    output =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/effective_pack_override/, fn ->
          verify_with_packaged_descriptors!(root)
        end
      end)

    assert output == ""
  end

  test "rejects a missing packaged descriptor BEAM before emitting a marker", %{root: root} do
    write_release_fixture!(root)

    output =
      capture_io(fn ->
        with_packaged_descriptors!(root, fn ->
          File.rm!(descriptor_beam_path(root, :allbert_kernel))

          assert_raise RuntimeError, ~r/descriptor_beam/, fn ->
            ReleaseAssemblyVerifier.verify_fixture!(root, @checkpoint)
          end
        end)
      end)

    assert output == ""
  end

  test "rejects packaged descriptor BEAM byte drift before emitting a marker", %{root: root} do
    write_release_fixture!(root)

    output =
      capture_io(fn ->
        with_packaged_descriptors!(root, fn ->
          path = descriptor_beam_path(root, :allbert_kernel)
          File.write!(path, File.read!(path) <> "tampered")

          assert_raise RuntimeError, ~r/descriptor_beam_container/, fn ->
            ReleaseAssemblyVerifier.verify_fixture!(root, @checkpoint)
          end
        end)
      end)

    assert output == ""
  end

  test "rejects a corrupt packaged descriptor BEAM before emitting a marker", %{root: root} do
    write_release_fixture!(root)

    output =
      capture_io(fn ->
        with_packaged_descriptors!(root, fn ->
          File.write!(descriptor_beam_path(root, :allbert_kernel), "not a BEAM")

          assert_raise RuntimeError, ~r/descriptor_beam_container/, fn ->
            ReleaseAssemblyVerifier.verify_fixture!(root, @checkpoint)
          end
        end)
      end)

    assert output == ""
  end

  test "accepts only the M1.a1 checkpoint before reading the release", %{root: root} do
    output =
      capture_io(fn ->
        assert_raise ArgumentError, ~r/unsupported release-assembly checkpoint/, fn ->
          ReleaseAssemblyVerifier.verify!(root, "v14-m1a3")
        end
      end)

    assert output == ""
  end

  test "rejects an undeclared Pack on a non-prefixed release application", %{root: root} do
    write_release_fixture!(root)
    add_nonprefixed_pack!(root)

    output =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/unexpected_raw_pack/, fn ->
          verify_with_packaged_descriptors!(root)
        end
      end)

    assert output == ""
  end

  test "rejects a Pack moved off its canonical first-party row before app atomization", %{
    root: root
  } do
    write_release_fixture!(root)
    atom_name = "allbert_unsealed_move_#{System.unique_integer([:positive, :monotonic])}"
    move_kernel_pack_off_canonical_row!(root, atom_name)

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    output =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/canonical_pack_declaration/, fn ->
          verify_with_packaged_descriptors!(root)
        end
      end)

    assert output == ""
    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
  end

  test "rejects unexpected loaded Pack declarations in canonical order", %{root: root} do
    write_release_fixture!(root)
    loaded = [:z_release_verifier_pack, :a_release_verifier_pack]

    Enum.each(loaded, fn application ->
      assert :ok =
               :application.load(
                 {:application, application,
                  [
                    vsn: ~c"1",
                    modules: [AllbertAssist.Pack.Kernel],
                    applications: [],
                    env: [allbert_pack: AllbertAssist.Pack.Kernel]
                  ]}
               )
    end)

    on_exit(fn -> Enum.each(loaded, &Application.unload/1) end)

    output =
      capture_io(fn ->
        assert_raise RuntimeError,
                     ~r/unexpected_loaded_pack_applications.*a_release_verifier_pack.*z_release_verifier_pack/,
                     fn ->
                       verify_with_packaged_descriptors!(root)
                     end
      end)

    assert output == ""
  end

  test "rejects symlinked ancestors inside the release root", %{root: root} do
    write_release_fixture!(root)
    release_version_root = Path.join([root, "releases", @version])
    target = Path.join(root, "release-version-target")
    File.rename!(release_version_root, target)
    File.ln_s!(target, release_version_root)

    output =
      capture_io(fn ->
        assert_raise RuntimeError, ~r/unsafe_release_path/, fn ->
          verify_with_packaged_descriptors!(root)
        end
      end)

    assert output == ""
  end

  test "direct sealed-spec load failure restores no-start application state", %{root: root} do
    write_release_fixture!(root)
    make_residual_spec_unloadable!(root)

    {output, status} = run_isolated_verifier(root, :error)

    assert status == 0, output
    assert output =~ "VERIFIER_RESULT=error:"
    assert output =~ "application_load"
    assert output =~ "STATE_RESTORED=true"
    refute output =~ "ALLBERT_RELEASE_ASSEMBLY_V1="
  end

  test "successful direct sealed-spec loads restore no-start application state", %{root: root} do
    write_release_fixture!(root)

    {output, status} = run_isolated_verifier(root, :ok)

    assert status == 0, output
    assert output =~ "ALLBERT_RELEASE_ASSEMBLY_V1="
    assert output =~ "VERIFIER_RESULT=ok"
    assert output =~ "STATE_RESTORED=true"
  end

  test "descriptor on-load state blocks the marker and is restored", %{root: root} do
    write_release_fixture!(root)
    write_stateful_kernel_descriptor!(root)

    {output, status} = run_isolated_verifier(root, :error)

    assert status == 0, output
    assert output =~ "descriptor_application_effect"
    assert output =~ "VERIFIER_RESULT=error:"
    assert output =~ "STATE_RESTORED=true"
    refute output =~ "ALLBERT_RELEASE_ASSEMBLY_V1="
  end

  test "transient descriptor application starts cannot evade the guard", %{root: root} do
    write_release_fixture!(root)
    write_stateful_kernel_descriptor!(root, transient?: true)

    {output, status} = run_isolated_verifier(root, :error)

    assert status == 0, output
    assert output =~ "descriptor_application_effect"
    assert output =~ "VERIFIER_RESULT=error:"
    assert output =~ "STATE_RESTORED=true"
    refute output =~ "ALLBERT_RELEASE_ASSEMBLY_V1="
  end

  test "strict packaged verification rejects a pre-started Allbert application", %{root: root} do
    write_release_fixture!(root)

    {output, status} =
      run_isolated_verifier(root, :error, start_application: :allbert_kernel)

    assert status == 0, output
    assert output =~ "started_allbert_applications"
    assert output =~ "STATE_RESTORED=true"
    refute output =~ "ALLBERT_RELEASE_ASSEMBLY_V1="
  end

  test "post-load reconciliation failure restores no-start application state", %{root: root} do
    write_release_fixture!(root)
    change_kernel_pack_id!(root)

    {output, status} = run_isolated_verifier(root, :error)

    assert status == 0, output
    assert output =~ "descriptor_id"
    assert output =~ "STATE_RESTORED=true"
    refute output =~ "ALLBERT_RELEASE_ASSEMBLY_V1="
  end

  test "topology and catalog drift fail before the marker", %{root: root} do
    cases = [
      {:rel_closure, &add_second_rel!/1, ~r/rel_closure/},
      {:hidden_rel_closure, &add_hidden_rel!/1, ~r/rel_closure/},
      {:hidden_app_closure, &add_hidden_application!/1, ~r/raw_application_closure/},
      {:application_order, &reverse_kernel_and_residual!/1, ~r/application_order/},
      {:permanent_mode, &make_composition_transient!/1, ~r/non_permanent_application/},
      {:version_parity, &change_composition_release_version!/1, ~r/release_version_mismatch/},
      {:dependency_dag, &remove_composition_dependency!/1, ~r/dependency_dag/},
      {:optional_allbert_dependency, &make_composition_dependency_optional!/1,
       ~r/optional_allbert_dependency/},
      {:unexpected_optional_allbert_dependency, &add_optional_allbert_dependency!/1,
       ~r/optional_allbert_dependency/},
      {:release_dependency_closure, &add_ghost_composition_dependency!/1,
       ~r/release_dependency_closure/},
      {:included_application_mismatch, &add_logger_included_application!/1,
       ~r/included_application_mismatch/},
      {:raw_included_applications, &add_raw_included_application!/1,
       ~r/raw_included_applications/},
      {:raw_descriptor, &add_composition_descriptor!/1, ~r/raw_descriptor/},
      {:raw_nil_descriptor, &add_composition_nil_pack!/1, ~r/invalid_app.*atom_list/},
      {:first_party_closure, &change_composition_repository!/1, ~r/first_party_provenance/},
      {:sealed_app_digest, &tamper_kernel_application!/1, ~r/app_digest_mismatch/},
      {:malformed_pack, &remove_kernel_pack!/1, ~r/malformed_pack/}
    ]

    Enum.each(cases, fn {name, mutate!, expected_error} ->
      case_root = Path.join(root, Atom.to_string(name))
      File.mkdir_p!(case_root)
      write_release_fixture!(case_root)
      mutate!.(case_root)

      output =
        capture_io(fn ->
          assert_raise RuntimeError, expected_error, fn ->
            verify_with_packaged_descriptors!(case_root)
          end
        end)

      assert output == ""
    end)
  end

  defp write_release_fixture!(root) do
    app_specs = Map.new(@release_applications, &{&1, app_spec(&1)})

    app_sha256 = Map.new(app_specs, fn {application, bytes} -> {application, sha256(bytes)} end)

    Enum.each(app_specs, fn {application, bytes} ->
      ebin = Path.join([root, "lib", "#{application}-#{@version}", "ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "#{application}.app"), bytes)
      maybe_write_descriptor_beam!(ebin, application)
    end)

    rel = release_spec()
    rel_path = Path.join([root, "releases", @version, "allbert.rel"])
    File.mkdir_p!(Path.dirname(rel_path))
    File.write!(rel_path, rel)

    manifest = %{
      "schema_version" => 1,
      "components" => [
        component("allbert_assist", "beam-allbert-assist", %{
          "schema_version" => 1,
          "id" => "allbert_assist",
          "descriptor_module" => "Elixir.AllbertAssist.Pack.Residual",
          "startup_role" => "native_effectful",
          "registry_order" => 100,
          "app_sha256" => app_sha256.allbert_assist
        }),
        component("allbert_assist_web", "beam-allbert-assist-web"),
        component("allbert_composition", "beam-allbert-composition"),
        component("allbert_kernel", "beam-allbert-kernel", %{
          "schema_version" => 1,
          "id" => "allbert_kernel",
          "descriptor_module" => "Elixir.AllbertAssist.Pack.Kernel",
          "startup_role" => "kernel_prerequisite",
          "registry_order" => 0,
          "app_sha256" => app_sha256.allbert_kernel
        })
      ]
    }

    File.write!(Path.join(root, "THIRD-PARTY-MANIFEST.json"), Jason.encode!(manifest))

    %{rel_sha256: sha256(rel), app_sha256: app_sha256}
  end

  defp component(application, id, pack \\ nil) do
    %{
      "application" => application,
      "id" => id,
      "kind" => "beam_app",
      "provenance" => %{"ecosystem" => "allbert", "repository" => @repository}
    }
    |> maybe_put_pack(pack)
  end

  defp maybe_put_pack(component, nil), do: component
  defp maybe_put_pack(component, pack), do: Map.put(component, "pack", pack)

  defp release_spec(applications \\ @release_applications) do
    applications =
      Enum.map_join(applications, ",\n", fn application ->
        "  {#{application}, \"#{@version}\", permanent}"
      end)

    """
    {release, {"allbert", "#{@version}"}, {erts, "15.0"},
     [#{applications}]}.
    """
  end

  defp app_spec(:allbert_kernel) do
    application_spec(
      :allbert_kernel,
      ["'Elixir.AllbertAssist.Pack.Kernel'"],
      ~w(kernel stdlib elixir logger crypto)a,
      "[{allbert_pack, 'Elixir.AllbertAssist.Pack.Kernel'}]"
    )
  end

  defp app_spec(:allbert_assist) do
    application_spec(
      :allbert_assist,
      ["'Elixir.AllbertAssist.Pack.Residual'"],
      ~w(kernel stdlib elixir logger allbert_kernel)a,
      "[{allbert_pack, 'Elixir.AllbertAssist.Pack.Residual'}]"
    )
  end

  defp app_spec(:allbert_composition) do
    application_spec(
      :allbert_composition,
      [],
      ~w(kernel stdlib elixir logger allbert_kernel allbert_assist)a,
      "[]"
    )
  end

  defp app_spec(:allbert_assist_web) do
    application_spec(
      :allbert_assist_web,
      [],
      ~w(kernel stdlib elixir logger allbert_assist allbert_composition)a,
      "[]"
    )
  end

  defp app_spec(application) when application in @support_applications do
    application_spec(application, [], [], "[]")
  end

  defp application_spec(application, modules, applications, env) do
    modules = Enum.join(modules, ", ")
    applications = Enum.map_join(applications, ", ", &Atom.to_string/1)

    """
    {application, #{application},
     [{vsn, "#{@version}"},
      {modules, [#{modules}]},
      {applications, [#{applications}]},
      {env, #{env}}]}.
    """
  end

  defp expected_projection_sha256(app_sha256) do
    kernel =
      ~s({"app_sha256":"#{app_sha256.allbert_kernel}","application":"allbert_kernel","component":"beam-allbert-kernel","descriptor_module":"Elixir.AllbertAssist.Pack.Kernel","id":"allbert_kernel","registry_order":0,"schema_version":1,"startup_role":"kernel_prerequisite"})

    residual =
      ~s({"app_sha256":"#{app_sha256.allbert_assist}","application":"allbert_assist","component":"beam-allbert-assist","descriptor_module":"Elixir.AllbertAssist.Pack.Residual","id":"allbert_assist","registry_order":100,"schema_version":1,"startup_role":"native_effectful"})

    sha256("[#{kernel},#{residual}]")
  end

  defp add_second_rel!(root) do
    path = Path.join([root, "releases", "duplicate", "other.rel"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, release_spec())
  end

  defp add_hidden_rel!(root) do
    path = Path.join([root, "releases", ".hidden", "hidden.rel"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, release_spec())
  end

  defp add_hidden_application!(root) do
    path = Path.join([root, "lib", ".hidden", "ebin", ".hidden.app"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, application_spec(:hidden, [], [], "[]"))
  end

  defp add_nonprefixed_pack!(root) do
    application = :native_pack
    ebin = Path.join([root, "lib", "#{application}-#{@version}", "ebin"])
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "#{application}.app"),
      application_spec(
        application,
        ["'Elixir.AllbertAssist.Pack.Kernel'"],
        ~w(kernel stdlib elixir logger)a,
        "[{allbert_pack, 'Elixir.AllbertAssist.Pack.Kernel'}]"
      )
    )

    File.write!(
      rel_path(root),
      release_spec(@release_applications ++ [:native_pack])
    )

    update_manifest!(root, fn manifest ->
      Map.update!(manifest, "components", fn components ->
        components ++
          [
            %{
              "application" => "native_pack",
              "id" => "beam-native-pack",
              "kind" => "beam_app",
              "provenance" => %{
                "ecosystem" => "hex",
                "repository" => "https://example.invalid/native-pack"
              }
            }
          ]
      end)
    end)
  end

  defp reverse_kernel_and_residual!(root) do
    File.write!(
      rel_path(root),
      release_spec(
        @support_applications ++
          ~w(allbert_assist allbert_kernel allbert_composition allbert_assist_web)a
      )
    )
  end

  defp make_composition_transient!(root) do
    replace_in_file!(
      rel_path(root),
      ~s({allbert_composition, "#{@version}", permanent}),
      ~s({allbert_composition, "#{@version}", transient})
    )
  end

  defp change_composition_release_version!(root) do
    replace_in_file!(
      rel_path(root),
      ~s({allbert_composition, "#{@version}", permanent}),
      ~s({allbert_composition, "9.9.9", permanent})
    )
  end

  defp remove_composition_dependency!(root) do
    File.write!(
      app_path(root, :allbert_composition),
      application_spec(
        :allbert_composition,
        [],
        ~w(kernel stdlib elixir logger allbert_kernel)a,
        "[]"
      )
    )
  end

  defp add_ghost_composition_dependency!(root) do
    File.write!(
      app_path(root, :allbert_composition),
      application_spec(
        :allbert_composition,
        [],
        ~w(kernel stdlib elixir logger allbert_kernel allbert_assist ghost_dependency)a,
        "[]"
      )
    )
  end

  defp make_composition_dependency_optional!(root) do
    path = app_path(root, :allbert_composition)

    replace_in_file!(
      path,
      "{applications, [kernel, stdlib, elixir, logger, allbert_kernel, allbert_assist]},\n  {env, []}",
      "{applications, [kernel, stdlib, elixir, logger, allbert_kernel, allbert_assist]},\n  {optional_applications, [allbert_assist]},\n  {env, []}"
    )
  end

  defp add_optional_allbert_dependency!(root) do
    path = app_path(root, :allbert_composition)

    File.write!(
      path,
      application_spec(
        :allbert_composition,
        [],
        ~w(kernel stdlib elixir logger allbert_kernel allbert_assist allbert_ghost)a,
        "[]"
      )
    )

    replace_in_file!(
      path,
      "{applications, [kernel, stdlib, elixir, logger, allbert_kernel, allbert_assist, allbert_ghost]},\n  {env, []}",
      "{applications, [kernel, stdlib, elixir, logger, allbert_kernel, allbert_assist, allbert_ghost]},\n  {optional_applications, [allbert_ghost]},\n  {env, []}"
    )
  end

  defp add_logger_included_application!(root) do
    path = app_path(root, :logger)

    replace_in_file!(
      path,
      "{applications, []},\n  {env, []}",
      "{applications, []},\n  {included_applications, [crypto]},\n  {env, []}"
    )
  end

  defp add_composition_descriptor!(root) do
    File.write!(
      app_path(root, :allbert_composition),
      application_spec(
        :allbert_composition,
        ["'Elixir.AllbertAssist.Pack.Kernel'"],
        ~w(kernel stdlib elixir logger allbert_kernel allbert_assist)a,
        "[{allbert_pack, 'Elixir.AllbertAssist.Pack.Kernel'}]"
      )
    )
  end

  defp add_composition_nil_pack!(root) do
    File.write!(
      app_path(root, :allbert_composition),
      application_spec(
        :allbert_composition,
        ["nil"],
        ~w(kernel stdlib elixir logger allbert_kernel allbert_assist)a,
        "[{allbert_pack, nil}]"
      )
    )
  end

  defp add_raw_included_application!(root) do
    path = app_path(root, :allbert_composition)

    replace_in_file!(
      path,
      "{applications, [kernel, stdlib, elixir, logger, allbert_kernel, allbert_assist]},\n  {env, []}",
      "{applications, [kernel, stdlib, elixir, logger, allbert_kernel, allbert_assist]},\n  {included_applications, [allbert_kernel]},\n  {env, []}"
    )
  end

  defp change_composition_repository!(root) do
    update_manifest!(root, fn manifest ->
      Map.update!(
        manifest,
        "components",
        &Enum.map(&1, fn component ->
          change_composition_component_repository(component)
        end)
      )
    end)
  end

  defp tamper_kernel_application!(root) do
    path = app_path(root, :allbert_kernel)
    File.write!(path, File.read!(path) <> "\n% tampered after manifest finalization\n")
  end

  defp make_residual_spec_unloadable!(root) do
    path = app_path(root, :allbert_assist)

    replace_in_file!(
      path,
      "{env, [{allbert_pack, 'Elixir.AllbertAssist.Pack.Residual'}]}",
      "{env, [{allbert_pack, 'Elixir.AllbertAssist.Pack.Residual'}]}, {mod, bad}"
    )

    app_sha256 = path |> File.read!() |> sha256()
    update_pack_field!(root, "allbert_assist", "app_sha256", app_sha256)
  end

  defp remove_kernel_pack!(root) do
    update_manifest!(root, fn manifest ->
      Map.update!(
        manifest,
        "components",
        &Enum.map(&1, fn component -> remove_kernel_pack(component) end)
      )
    end)
  end

  defp change_kernel_pack_id!(root) do
    update_pack_field!(root, "allbert_kernel", "id", "changed_kernel")
  end

  defp move_kernel_pack_off_canonical_row!(root, atom_name) do
    path = app_path(root, :allbert_kernel)

    replace_in_file!(
      path,
      "{modules, ['Elixir.AllbertAssist.Pack.Kernel']}",
      "{modules, ['Elixir.AllbertAssist.Pack.Kernel', #{atom_name}]}"
    )

    update_manifest!(root, fn manifest ->
      {kernel, others} =
        manifest
        |> Map.fetch!("components")
        |> Enum.split_with(&(&1["application"] == "allbert_kernel"))

      [kernel] = kernel
      pack = Map.fetch!(kernel, "pack")
      canonical = Map.delete(kernel, "pack")

      moved = %{
        "application" => "allbert_kernel",
        "id" => "beam-allbert-kernel",
        "kind" => "external",
        "pack" => pack,
        "provenance" => %{
          "ecosystem" => "malicious",
          "repository" => "https://example.invalid/moved-pack"
        }
      }

      Map.put(manifest, "components", [canonical, moved | others])
    end)
  end

  defp update_pack_field!(root, application, field, value) do
    update_manifest!(root, fn manifest ->
      components =
        manifest
        |> Map.fetch!("components")
        |> Enum.map(&update_pack_component(&1, application, field, value))

      Map.put(manifest, "components", components)
    end)
  end

  defp update_pack_component(
         %{"application" => application} = component,
         application,
         field,
         value
       ),
       do: put_in(component, ["pack", field], value)

  defp update_pack_component(component, _application, _field, _value), do: component

  defp remove_kernel_pack(%{"application" => "allbert_kernel"} = component),
    do: Map.put(component, "pack", nil)

  defp remove_kernel_pack(component), do: component

  defp change_composition_component_repository(
         %{"application" => "allbert_composition"} = component
       ),
       do: put_in(component, ["provenance", "repository"], "https://example.invalid")

  defp change_composition_component_repository(component), do: component

  defp replace_in_file!(path, before, after_text) do
    contents = File.read!(path)
    replaced = String.replace(contents, before, after_text)
    assert replaced != contents
    File.write!(path, replaced)
  end

  defp update_manifest!(root, fun) do
    path = Path.join(root, "THIRD-PARTY-MANIFEST.json")
    manifest = path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(path, Jason.encode!(manifest))
  end

  defp rel_path(root), do: Path.join([root, "releases", @version, "allbert.rel"])

  defp app_path(root, application),
    do: Path.join([root, "lib", "#{application}-#{@version}", "ebin", "#{application}.app"])

  defp maybe_write_descriptor_beam!(ebin, application) do
    case descriptor_module(application) do
      nil ->
        :ok

      module ->
        {^module, bytes, _path} = :code.get_object_code(module)
        File.write!(Path.join(ebin, "#{module}.beam"), bytes)
    end
  end

  defp verify_with_packaged_descriptors!(root) do
    with_packaged_descriptors!(root, fn ->
      ReleaseAssemblyVerifier.verify_fixture!(root, @checkpoint)
    end)
  end

  defp with_packaged_descriptors!(root, fun) do
    snapshots =
      Enum.map(~w(allbert_kernel allbert_assist)a, fn application ->
        module = descriptor_module(application)
        loaded = :code.is_loaded(module)
        {^module, original_bytes, object_path} = :code.get_object_code(module)
        original_path = if loaded == false, do: object_path, else: :code.which(module)
        packaged_path = descriptor_beam_path(root, application)
        packaged_bytes = File.read!(packaged_path)
        packaged_ebin = Path.dirname(packaged_path)

        purge_code!(module)
        true = Code.prepend_path(packaged_ebin)

        assert {:module, ^module} =
                 :code.load_binary(module, String.to_charlist(packaged_path), packaged_bytes)

        %{
          module: module,
          loaded: loaded,
          path: original_path,
          bytes: original_bytes,
          packaged_ebin: packaged_ebin
        }
      end)

    try do
      fun.()
    after
      Enum.reverse(snapshots)
      |> Enum.each(fn snapshot ->
        restore_code!(snapshot)
        true = Code.delete_path(snapshot.packaged_ebin)
      end)
    end
  end

  defp restore_code!(%{module: module, loaded: false}) do
    purge_code!(module)
    :ok
  end

  defp restore_code!(%{module: module, path: path, bytes: bytes}) do
    purge_code!(module)
    assert {:module, ^module} = :code.load_binary(module, path, bytes)
    :ok
  end

  defp purge_code!(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    :ok
  end

  defp descriptor_beam_path(root, application) do
    module = descriptor_module(application)
    Path.join([root, "lib", "#{application}-#{@version}", "ebin", "#{module}.beam"])
  end

  defp descriptor_module(:allbert_kernel), do: AllbertAssist.Pack.Kernel
  defp descriptor_module(:allbert_assist), do: AllbertAssist.Pack.Residual
  defp descriptor_module(_application), do: nil

  defp write_stateful_kernel_descriptor!(root, opts \\ []) do
    module = AllbertAssist.Pack.Kernel
    loaded = :code.is_loaded(module)
    {^module, original_bytes, object_path} = :code.get_object_code(module)
    original_path = if loaded == false, do: object_path, else: :code.which(module)
    previous_env = Application.fetch_env(:release_verifier_unloaded_probe, :flag)

    transient_cleanup =
      if Keyword.get(opts, :transient?, false) do
        """
        :ok = Application.stop(:release_verifier_on_load_probe)
        :ok = Application.unload(:release_verifier_on_load_probe)
        """
      else
        ""
      end

    source = """
    defmodule AllbertAssist.Pack.Kernel do
      @on_load :activate_probe

      def activate_probe do
        :ok =
          :application.load(
            {:application, :release_verifier_on_load_probe,
             [vsn: ~c"1", modules: [], applications: []]}
          )

        :ok = Application.start(:release_verifier_on_load_probe)
        Application.put_env(:release_verifier_unloaded_probe, :flag, :mutated)
        #{transient_cleanup}
        :ok
      end

      def descriptor do
        %AllbertAssist.Pack.Descriptor{
          schema_version: 1,
          id: "allbert_kernel",
          application: :allbert_kernel,
          application_version: "#{@version}",
          capability_tier: :kernel,
          provenance: %{source: :signed_release, component: "beam-allbert-kernel"},
          registry_order: 0
        }
      end
    end
    """

    malicious_bytes =
      try do
        [{^module, bytes}] = Code.compile_string(source, "stateful_pack_kernel.ex")
        bytes
      after
        Application.stop(:release_verifier_on_load_probe)
        Application.unload(:release_verifier_on_load_probe)
        restore_env(:release_verifier_unloaded_probe, :flag, previous_env)
        purge_code!(module)

        if loaded != false do
          assert {:module, ^module} =
                   :code.load_binary(module, original_path, original_bytes)
        end
      end

    File.write!(descriptor_beam_path(root, :allbert_kernel), malicious_bytes)
  end

  defp run_isolated_verifier(root, expected_result, opts \\ []) do
    start_application = Keyword.get(opts, :start_application)

    eval = """
    root = #{inspect(root)}
    checkpoint = #{inspect(@checkpoint)}
    expected_result = #{inspect(expected_result)}
    start_application = #{inspect(start_application)}
    descriptors = [
      {AllbertAssist.Pack.Kernel, Path.join([root, "lib", "allbert_kernel-#{@version}", "ebin", "Elixir.AllbertAssist.Pack.Kernel.beam"])},
      {AllbertAssist.Pack.Residual, Path.join([root, "lib", "allbert_assist-#{@version}", "ebin", "Elixir.AllbertAssist.Pack.Residual.beam"])}
    ]

    Enum.each(descriptors, fn {module, path} ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      true = Code.prepend_path(Path.dirname(path))
    end)

    if start_application do
      {:ok, _started} = Application.ensure_all_started(start_application)
    end

    snapshot = fn ->
      loaded = Application.loaded_applications() |> Map.new(fn {app, description, version} -> {app, {description, version}} end)

      environment =
        :ac_tab
        |> :ets.tab2list()
        |> Enum.reduce(%{}, fn
          {{:env, app, _key}, _value}, state ->
            Map.put_new_lazy(state, app, fn -> app |> Application.get_all_env() |> Map.new() end)

          _record, state ->
            state
        end)

      %{
        loaded: loaded,
        started: Application.started_applications() |> Map.new(fn {app, description, version} -> {app, {description, version}} end),
        environment: environment
      }
    end

    before = snapshot.()

    result =
      try do
        AllbertAssist.Pack.ReleaseAssemblyVerifier.verify!(root, checkpoint)
        :ok
      rescue
        error -> {:error, Exception.message(error)}
      end

    after_state = snapshot.()
    IO.puts("STATE_RESTORED=\#{before == after_state}")

    case {expected_result, result} do
      {:ok, :ok} -> IO.puts("VERIFIER_RESULT=ok")
      {:error, {:error, message}} -> IO.puts("VERIFIER_RESULT=error:\#{message}")
      _mismatch -> System.halt(91)
    end
    """

    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "--no-start", "--eval", eval],
      cd: @repo_root,
      env: [
        {"MIX_ENV", "test"},
        {"ALLBERT_HOME", Path.join(root, "isolated-home")},
        {"ALLBERT_HOME_DIR", Path.join(root, "isolated-home")}
      ],
      stderr_to_stdout: true
    )
  end

  defp restore_env(application, key, {:ok, value}),
    do: Application.put_env(application, key, value)

  defp restore_env(application, key, :error), do: Application.delete_env(application, key)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
