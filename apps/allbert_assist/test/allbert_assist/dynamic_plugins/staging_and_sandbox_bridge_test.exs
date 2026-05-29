defmodule AllbertAssist.DynamicPlugins.StagingAndSandboxBridgeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Audit
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.Staging
  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter
  alias AllbertAssist.Settings

  defmodule CompletingDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command, _policy) do
      ReportWriter.write(bundle, %Report{
        status: :completed,
        backend: id(),
        command: CommandSpec.summary(command),
        metadata: %{fixture_backend?: true}
      })
    end

    def cleanup(_bundle), do: :ok
  end

  defmodule FailingDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command, _policy) do
      ReportWriter.write(bundle, %Report{
        status: :failed,
        backend: id(),
        command: CommandSpec.summary(command),
        diagnostics: [%{reason: :fixture_failure}]
      })
    end

    def cleanup(_bundle), do: :ok
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "stage_draft builds a project-shaped tree and scan-mounted bundle params" do
    project = fixture_project("stage-valid")
    draft = write_valid_draft("weather_summary")

    assert {:ok, staging} =
             DynamicPlugins.stage_draft(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"]
             )

    assert File.regular?(Path.join(staging.root, source_compiled_path(draft.slug)))
    assert File.regular?(Path.join(staging.root, test_compiled_path(draft.slug)))
    assert staging.focused_test_paths == [test_compiled_path(draft.slug)]

    assert %{
             project_root: root,
             draft_paths: [source_path],
             test_paths: [test_path]
           } = Staging.bundle_params(staging)

    assert root == staging.root
    assert source_path == source_compiled_path(draft.slug)
    assert test_path == test_compiled_path(draft.slug)

    File.rm_rf!(staging.root)
  end

  test "stage_draft rejects generated files outside the reserved compile path" do
    project = fixture_project("stage-invalid-path")

    draft =
      write_valid_draft("bad_path",
        source_compiled_path: "apps/allbert_assist/lib/allbert_assist/core_replacement.ex"
      )

    assert {:error,
            {:invalid_manifest_entry,
             {:compiled_path_outside_generated_namespace,
              "apps/allbert_assist/lib/allbert_assist/core_replacement.ex"}}} =
             DynamicPlugins.stage_draft(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"]
             )
  end

  test "stage_draft rejects compile-visible bytes without matching scanned source hashes" do
    project = fixture_project("stage-unscanned")
    draft = write_valid_draft("unscanned_path", omit_source_hash?: true)
    source_rel = source_rel_path()

    assert {:error, {:unscanned_compile_path, [^source_rel]}} =
             DynamicPlugins.stage_draft(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"]
             )
  end

  test "stage_draft rejects scanned bytes that are not compile-visible" do
    project = fixture_project("stage-extra-scan")
    draft = write_valid_draft("extra_scan", extra_scan?: true)

    assert {:error, {:scanned_but_not_compiled, ["source/lib/extra.ex"]}} =
             DynamicPlugins.stage_draft(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"]
             )
  end

  test "run_draft_gate records denied evidence when v0.36 sandbox is disabled" do
    enable_dynamic_codegen!()

    project = fixture_project("gate-disabled")
    draft = write_valid_draft("gate_disabled")

    assert {:ok, result} =
             DynamicPlugins.run_draft_gate(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"],
               profiles: [:compile]
             )

    assert result.status == :denied
    assert result.draft.tier == "draft"

    assert {:ok, updated} = DynamicPlugins.get_draft(draft.slug)
    assert updated.gate["status"] == "denied"
    assert File.regular?(updated.gate["sandbox_report_path"])
  end

  test "run_draft_gate records failed evidence without changing the draft tier" do
    enable_dynamic_codegen_and_sandbox!()

    project = fixture_project("gate-failed")
    draft = write_valid_draft("gate_failed", diagnostics: [%{reason: :existing}])

    assert {:ok, result} =
             DynamicPlugins.run_draft_gate(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"],
               profiles: [:compile],
               backends: [FailingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert result.status == :failed
    assert result.draft.tier == "draft"

    assert {:ok, updated} = DynamicPlugins.get_draft(draft.slug)
    assert updated.gate["status"] == "failed"
    assert inspect(updated.diagnostics) =~ "fixture_failure"
    assert inspect(updated.diagnostics) =~ "existing"
    assert [%{"kind" => "gate", "status" => "failed"} | _] = updated.gate["reports"]
    assert File.read!(Audit.audit_path()) =~ "sandbox_report_recorded"
  end

  test "trial and gate pass advance only evidence tiers" do
    enable_dynamic_codegen_and_sandbox!()

    project = fixture_project("gate-passed")
    draft = write_valid_draft("gate_passed")

    assert {:ok, trial} =
             DynamicPlugins.run_draft_trial(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"],
               profiles: [:compile],
               backends: [CompletingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert trial.status == :completed
    assert trial.draft.tier == "sandbox_compiled"

    assert {:ok, gate} =
             DynamicPlugins.run_draft_gate(draft.slug,
               project_root: project,
               project_paths: ["mix.exs", "apps"],
               profiles: [:compile],
               backends: [CompletingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert gate.status == :completed
    assert gate.draft.tier == "gate_passed"

    assert {:ok, updated} = DynamicPlugins.get_draft(draft.slug)
    assert updated.gate["status"] == "passed"
    assert updated.gate["sandbox_report_id"]
    assert [%{"kind" => "gate"}, %{"kind" => "trial"}] = updated.gate["reports"]
    assert File.read!(Audit.audit_path()) =~ "tier_transition"
  end

  test "registered dynamic draft trial action routes through Security Central and sandbox bridge" do
    enable_dynamic_codegen!()

    project = fixture_project("action-trial-disabled")
    draft = write_valid_draft("action_trial")

    assert {:ok, response} =
             Runner.run(
               "run_dynamic_draft_trial",
               %{
                 slug: draft.slug,
                 project_root: project,
                 project_paths: ["mix.exs", "apps"],
                 profiles: [:compile]
               },
               %{actor: "dynamic-action-test", channel: :test}
             )

    assert response.status == :denied
    assert response.draft.tier == "draft"
    assert [%{name: "run_dynamic_draft_trial", status: :denied}] = response.actions
  end

  defp enable_dynamic_codegen! do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "dynamic_codegen" => %{"enabled" => true}
             })
  end

  defp enable_dynamic_codegen_and_sandbox! do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "dynamic_codegen" => %{"enabled" => true},
               "sandbox" => %{
                 "elixir" => %{
                   "enabled" => true,
                   "backend" => "docker",
                   "image" => "fixture:local"
                 }
               }
             })
  end

  defp write_valid_draft(slug, opts \\ []) do
    source_rel = source_rel_path()
    test_rel = test_rel_path()
    source_compiled = Keyword.get(opts, :source_compiled_path, source_compiled_path(slug))
    test_compiled = Keyword.get(opts, :test_compiled_path, test_compiled_path(slug))

    source_abs = Path.join(MetadataStore.draft_root(slug), source_rel)
    test_abs = Path.join(MetadataStore.draft_root(slug), test_rel)
    File.mkdir_p!(Path.dirname(source_abs))
    File.mkdir_p!(Path.dirname(test_abs))
    File.write!(source_abs, source_body(slug))
    File.write!(test_abs, test_body(slug))

    assert {:ok, source_hash} = MetadataStore.hash_file(source_abs)
    assert {:ok, test_hash} = MetadataStore.hash_file(test_abs)

    source_hashes =
      %{}
      |> maybe_put_hash(source_rel, source_hash, Keyword.get(opts, :omit_source_hash?, false))
      |> Map.put(test_rel, test_hash)
      |> maybe_put_extra_scan(opts)

    scan_paths =
      [source_rel, test_rel]
      |> maybe_add_extra_scan_path(opts)

    assert {:ok, draft} =
             DynamicPlugins.put_draft(%{
               slug: slug,
               revision: "rev_test",
               producer: "test",
               target_shapes: ["action"],
               source_hashes: source_hashes,
               compiled_paths: [source_compiled, test_compiled],
               scan_paths: scan_paths,
               diagnostics: Keyword.get(opts, :diagnostics, [])
             })

    assert :ok =
             MetadataStore.put_manifest(slug, %{
               "files" => [
                 %{"source_path" => source_rel, "compiled_path" => source_compiled}
               ],
               "tests" => [
                 %{"source_path" => test_rel, "compiled_path" => test_compiled}
               ],
               "focused_test_paths" => [test_compiled]
             })

    draft
  end

  defp maybe_put_hash(map, _path, _hash, true), do: map
  defp maybe_put_hash(map, path, hash, false), do: Map.put(map, path, hash)

  defp maybe_put_extra_scan(map, opts) do
    if Keyword.get(opts, :extra_scan?, false) do
      extra_rel = "source/lib/extra.ex"
      extra_abs = Path.join(MetadataStore.draft_root("extra_scan"), extra_rel)
      File.mkdir_p!(Path.dirname(extra_abs))
      File.write!(extra_abs, "defmodule ExtraScan, do: nil\n")
      assert {:ok, hash} = MetadataStore.hash_file(extra_abs)
      Map.put(map, extra_rel, hash)
    else
      map
    end
  end

  defp maybe_add_extra_scan_path(paths, opts) do
    if Keyword.get(opts, :extra_scan?, false), do: paths ++ ["source/lib/extra.ex"], else: paths
  end

  defp source_rel_path, do: "source/lib/action.ex"
  defp test_rel_path, do: "tests/action_test.exs"

  defp source_compiled_path(slug) do
    "apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/#{slug}/action.ex"
  end

  defp test_compiled_path(slug) do
    "apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/#{slug}/action_test.exs"
  end

  defp source_body(_slug) do
    """
    defmodule AllbertAssist.DynamicPlugins.Generated.Sample.Action do
      def run(_params, _context), do: {:ok, %{status: :completed}}
    end
    """
  end

  defp test_body(_slug) do
    """
    defmodule AllbertAssist.DynamicPlugins.Generated.Sample.ActionTest do
      use ExUnit.Case, async: true

      test "generated fixture" do
        assert true
      end
    end
    """
  end

  defp fixture_project(name) do
    root = temp_path("project-#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "apps/allbert_assist/lib/allbert_assist"))
    File.mkdir_p!(Path.join(root, "apps/allbert_assist/test/allbert_assist"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0", start_permanent: false]
    end
    """)

    File.write!(
      Path.join(root, "apps/allbert_assist/mix.exs"),
      "defmodule Fixture.App.MixProject, do: nil\n"
    )

    root
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-staging-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
