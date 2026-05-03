defmodule AllbertAssist.Execution.SkillScriptSpecTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Skills.RunSkillScript
  alias AllbertAssist.Execution.SkillScriptSpec
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-skill-script-spec-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    project_root = Path.join(root, "project")

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")

    put_script_policy!(workspace)
    script_path = write_script_skill!(home, "demo-script", executable?: true)

    on_exit(fn ->
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, home: home, workspace: workspace, project_root: project_root, script_path: script_path}
  end

  test "trusted inventoried executable script resolves with digest and metadata", context do
    assert {:ok, spec} =
             SkillScriptSpec.normalize(
               %{
                 skill_name: "demo-script",
                 script_path: "scripts/hello",
                 args: ["README.md", "token=sk-testsecret"],
                 cwd: context.workspace,
                 env: %{"PATH" => "/bin"},
                 timeout_ms: 1000,
                 max_output_bytes: 2048
               },
               context: %{disable_legacy_built_ins: true},
               run_id: "run-fixture"
             )

    assert SkillScriptSpec.allowed?(spec)
    assert spec.skill_name == "demo-script"
    assert spec.skill_source_scope == :user_native
    assert spec.skill_trust_status == :trusted
    assert spec.script_path == "scripts/hello"
    assert spec.resolved_script_path == context.script_path
    assert spec.resolved_executable == context.script_path
    assert spec.launch_mode == :direct_executable
    assert spec.actual_sha256 == spec.expected_sha256
    assert Regex.match?(~r/^[a-f0-9]{64}$/, spec.actual_sha256)
    assert spec.env["ALLBERT_SKILL_NAME"] == "demo-script"
    assert spec.env["PATH"] == "/bin"
    assert [%{original: "README.md", allowed?: true}] = spec.path_operands

    summary = SkillScriptSpec.summary(spec)
    assert summary.args == ["README.md", "[REDACTED]"]

    assert summary.env_keys == [
             "ALLBERT_RUN_ID",
             "ALLBERT_SKILL_NAME",
             "ALLBERT_SKILL_SCRIPT_PATH",
             "ALLBERT_SKILL_SCRIPT_SHA256",
             "PATH"
           ]
  end

  test "default cwd is an internal per-run path outside allowed-root requirements", context do
    assert {:ok, spec} =
             SkillScriptSpec.normalize(
               %{
                 skill_name: "demo-script",
                 script_path: "scripts/hello",
                 args: []
               },
               context: %{disable_legacy_built_ins: true},
               run_id: "run-default-cwd"
             )

    assert spec.cwd_source == :internal

    assert spec.resolved_cwd ==
             Path.join([
               context.home,
               "execution",
               "skill-scripts",
               "runs",
               "run-default-cwd",
               "cwd"
             ])
  end

  test "script policy and skill trust deny before confirmation", context do
    assert {:ok, _setting} =
             Settings.put("execution.skill_scripts.enabled", false, %{audit?: false})

    assert {:error, disabled_policy} =
             SkillScriptSpec.normalize(valid_params(context),
               context: %{disable_legacy_built_ins: true}
             )

    assert disabled_policy.denial_reason == :skill_scripts_disabled

    put_script_policy!(context.workspace)
    assert {:ok, _setting} = Settings.put("skills.disabled", ["demo-script"], %{audit?: false})

    assert {:error, disabled_skill} =
             SkillScriptSpec.normalize(valid_params(context),
               context: %{disable_legacy_built_ins: true}
             )

    assert disabled_skill.denial_reason == :skill_not_found_or_untrusted

    write_project_script_skill!(context.project_root, "project-script")

    assert {:error, untrusted_project} =
             SkillScriptSpec.normalize(
               %{valid_params(context) | skill_name: "project-script"},
               context: %{project_root: context.project_root, disable_legacy_built_ins: true}
             )

    assert untrusted_project.denial_reason == :skill_not_found_or_untrusted
  end

  test "missing non-script hidden and path-escaping resources are denied", context do
    assert_denial(context, "/tmp/nope", :absolute_script_path)
    assert_denial(context, "../outside", :path_traversal)
    assert_denial(context, "scripts/.hidden", :hidden_script_path)
    assert_denial(context, "scripts/missing", :script_resource_not_found)
    assert_denial(context, "references/ref.md", :non_script_resource)
  end

  test "digest drift and non-executable scripts are denied", context do
    assert {:ok, spec} =
             SkillScriptSpec.normalize(valid_params(context),
               context: %{disable_legacy_built_ins: true}
             )

    File.write!(context.script_path, "#!/usr/bin/env sh\nprintf drifted\\n")

    assert {:error, drifted} =
             SkillScriptSpec.normalize(
               Map.put(valid_params(context), :expected_sha256, spec.actual_sha256),
               context: %{disable_legacy_built_ins: true}
             )

    assert drifted.denial_reason == :digest_mismatch

    write_script_skill!(context.home, "non-exec-script", executable?: false)

    assert {:error, non_exec} =
             SkillScriptSpec.normalize(
               %{valid_params(context) | skill_name: "non-exec-script"},
               context: %{disable_legacy_built_ins: true}
             )

    assert non_exec.denial_reason == :script_not_executable
  end

  test "cwd env limits and path-like args are constrained by local execution policy", context do
    assert {:error, cwd_denied} =
             SkillScriptSpec.normalize(
               %{valid_params(context) | cwd: System.tmp_dir!()},
               context: %{disable_legacy_built_ins: true}
             )

    assert {:cwd_outside_allowed_roots, _path} = cwd_denied.denial_reason

    assert {:error, env_denied} =
             SkillScriptSpec.normalize(
               Map.put(valid_params(context), :env, %{"SECRET_TOKEN" => "nope"}),
               context: %{disable_legacy_built_ins: true}
             )

    assert env_denied.denial_reason == {:env_not_allowed, ["SECRET_TOKEN"]}

    assert {:error, path_denied} =
             SkillScriptSpec.normalize(
               %{valid_params(context) | args: ["/etc/passwd"]},
               context: %{disable_legacy_built_ins: true}
             )

    assert {:path_operands_outside_allowed_roots, [%{original: "/etc/passwd"}]} =
             path_denied.denial_reason

    assert {:error, timeout_denied} =
             SkillScriptSpec.normalize(
               Map.put(valid_params(context), :timeout_ms, 6000),
               context: %{disable_legacy_built_ins: true}
             )

    assert timeout_denied.denial_reason == {:timeout_exceeds_policy, 6000, 5000}
  end

  test "run_skill_script action returns resolved inert spec without creating confirmation",
       context do
    assert {:ok, response} =
             RunSkillScript.run(valid_params(context), %{disable_legacy_built_ins: true})

    assert response.status == :needs_confirmation
    assert response.message =~ "Skill script spec is valid and ready for operator approval"
    assert response.message =~ "Nothing has executed yet"
    assert response.script.skill_name == "demo-script"

    assert response.actions == [
             %{
               name: "run_skill_script",
               status: :spec_resolved,
               permission: :skill_script_execute,
               permission_decision: response.permission_decision,
               execution: :pending_confirmation_not_created,
               script: response.script,
               input: %{
                 skill_name: "demo-script",
                 script_path: "scripts/hello",
                 args: [],
                 cwd: context.workspace,
                 env_keys: [],
                 timeout_ms: nil,
                 max_output_bytes: nil,
                 expected_sha256: nil
               },
               diagnostics: [:v0_09_confirmation_lands_in_m3, :v0_09_runner_lands_in_m4]
             }
           ]
  end

  defp valid_params(context) do
    %{
      skill_name: "demo-script",
      script_path: "scripts/hello",
      args: [],
      cwd: context.workspace
    }
  end

  defp assert_denial(context, script_path, reason) do
    assert {:error, spec} =
             SkillScriptSpec.normalize(
               %{valid_params(context) | script_path: script_path},
               context: %{disable_legacy_built_ins: true}
             )

    assert spec.denial_reason == reason
  end

  defp put_script_policy!(workspace) do
    settings = %{
      "permissions" => %{"skill_script_execute" => "allowed"},
      "execution" => %{
        "local" => %{
          "allowed_roots" => [workspace],
          "env_allowlist" => ["PATH"],
          "max_timeout_ms" => 5000,
          "max_output_bytes" => 4096
        },
        "skill_scripts" => %{"enabled" => true}
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp write_script_skill!(home, name, opts) do
    skill_root = Path.join([home, "skills", name])
    script_path = Path.join([skill_root, "scripts", "hello"])

    File.mkdir_p!(Path.dirname(script_path))
    File.mkdir_p!(Path.join(skill_root, "references"))

    File.write!(Path.join(skill_root, "SKILL.md"), skill_markdown(name))
    File.write!(script_path, "#!/usr/bin/env sh\nprintf 'hello from #{name}\\n'\n")
    File.write!(Path.join([skill_root, "references", "ref.md"]), "reference\n")

    if Keyword.fetch!(opts, :executable?) do
      File.chmod!(script_path, 0o755)
    else
      File.chmod!(script_path, 0o644)
    end

    script_path
  end

  defp write_project_script_skill!(project_root, name) do
    skill_root = Path.join([project_root, ".allbert", "skills", name])
    script_path = Path.join([skill_root, "scripts", "hello"])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(Path.join(skill_root, "SKILL.md"), skill_markdown(name))
    File.write!(script_path, "#!/usr/bin/env sh\nprintf project\\n")
    File.chmod!(script_path, 0o755)

    script_path
  end

  defp skill_markdown(name) do
    """
    ---
    name: #{name}
    description: #{name} test script skill.
    metadata:
      allbert.kind: capability
      allbert.actions: run_skill_script
      allbert.permissions: skill_script_execute
      allbert.confirmation: required
    ---

    Run the bundled script only through Allbert.
    """
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
