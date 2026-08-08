defmodule AllbertAssist.SecurityCentralIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Security
  alias AllbertAssist.Security.Context
  alias AllbertAssist.Settings

  # These two rows assert Security Central against residual runtime rather than
  # against its own contracts: one loads skill trust through the Skills
  # registry, the other renders operator status from fully resolved settings.
  # Stubbing either would leave the row asserting the stub, so both stay here.

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-security-central-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "loads selected skill trust and provenance from the registry", %{root: root} do
    built_in_root = Path.join(root, "built-in-skills")
    write_skill(built_in_root, "trusted-helper", "trusted-helper")

    context =
      Context.normalize(:read_only, %{
        built_in_root: built_in_root,
        selected_skill: "trusted-helper"
      })

    assert context.skill.name == "trusted-helper"
    assert context.skill.source_scope == :built_in
    assert context.skill.trust_status == :trusted
    assert context.skill.lookup_status == :found
  end

  test "returns redacted operator security status" do
    status = Security.status(%{request: %{operator_id: "local", channel: :test}})

    assert Enum.any?(status.permission_defaults, &(&1.permission == :command_execute))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :package_install))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :online_skill_import))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :skill_write))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :dynamic_codegen_request))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :dynamic_codegen_discard))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :skill_script_execute))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :confirmation_decide))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :tool_discovery))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :mcp_server_connect))
    assert Enum.any?(status.safety_floors, &(&1.permission == :unknown and &1.floor == :denied))
    assert status.secret_status.providers >= 1
    assert status.redaction_posture.secret_ref_display == "[SECRET_REF]"
    assert Enum.any?(status.future_boundaries, &(&1.name == :shell_sandbox))

    assert Enum.any?(
             status.future_boundaries,
             &(&1.name == :external_adapters_and_imports and &1.status == :implemented)
           )

    assert status.capability_boundaries.external_services.enabled == false
    assert status.capability_boundaries.package_installs.allowed_managers == ["npm"]
    assert status.capability_boundaries.online_skill_import.allowed_sources == ["skills_sh"]
    refute inspect(status) =~ "secret://"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp write_skill(root, directory, name) do
    skill_root = Path.join(root, directory)
    File.mkdir_p!(skill_root)

    File.write!(Path.join(skill_root, "SKILL.md"), """
    ---
    name: #{name}
    description: #{name} test skill.
    ---

    ## Workflow

    Inspect only.
    """)
  end
end
