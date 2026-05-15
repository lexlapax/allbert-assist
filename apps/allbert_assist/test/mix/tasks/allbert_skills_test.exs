defmodule Mix.Tasks.Allbert.SkillsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.DirectImport
  alias AllbertAssist.Skills.Online.RegistryClient
  alias Mix.Tasks.Allbert.Confirmations, as: ConfirmationsTask
  alias Mix.Tasks.Allbert.Skills, as: SkillsTask

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_client_config = Application.get_env(:allbert_assist, RegistryClient)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_direct_import_config = Application.get_env(:allbert_assist, DirectImport)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-skills-task-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")

    Application.put_env(:allbert_assist, Paths,
      home: home,
      skills_root: Path.join(home, "skills")
    )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(home, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, RegistryClient,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:allbert_assist, DirectImport,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    PluginRegistry.register_module(StockSage.Plugin)

    on_exit(fn ->
      restore_env(RegistryClient, original_client_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(DirectImport, original_direct_import_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.skills")
      Mix.Task.reenable("allbert.confirmations")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "validate prints local skill diagnostics" do
    output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["validate", fixture("allbert-capability")])
      end)

    assert output =~ "Validation: valid"
    assert output =~ "Name: allbert-capability"
    assert output =~ "Contract: valid"
    assert output =~ "Execution eligible: false"
  end

  test "list prints discovered plugin skills" do
    output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["list"])
      end)

    assert output =~ "Skills:"
    assert output =~ "list-analyses"
    assert output =~ "queue-analysis"
    assert output =~ "plugin=stocksage"
  end

  test "create writes a local skill through the registered action boundary", %{root: root} do
    skill_root = Path.join(root, "created-skills")

    output =
      capture_io(fn ->
        assert :ok =
                 SkillsTask.run([
                   "create",
                   "demo-memory",
                   "append_memory",
                   "memory_write",
                   "Save",
                   "a",
                   "memory",
                   "helper",
                   "--root",
                   skill_root
                 ])
      end)

    assert output =~ "Created:"
    assert output =~ "Validation: valid"
    assert File.exists?(Path.join([skill_root, "demo-memory", "SKILL.md"]))
  end

  test "create raises for unknown actions" do
    assert_raise Mix.Error, ~r/invalid_contract/, fn ->
      SkillsTask.run(["create", "bad-helper", "missing_action", "read_only"])
    end
  end

  test "run creates pending script confirmation through the action boundary", %{root: root} do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    write_script_skill!(Path.join(root, "home"), "demo-script")
    put_script_policy!(workspace)

    output =
      capture_io(fn ->
        assert :ok =
                 SkillsTask.run([
                   "run",
                   "demo-script",
                   "scripts/hello",
                   "--cwd",
                   workspace,
                   "--",
                   "arg"
                 ])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "Skill: demo-script"
    assert output =~ "Script: scripts/hello"
    assert output =~ "Confirmation:"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "run_skill_script"
    assert pending["params_summary"]["script_path"] == "scripts/hello"
  end

  test "online import task creates confirmation and approval imports disabled skill" do
    put_online_policy!()

    output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["import-online", "skills_sh/vercel-labs/skills/find-skills"])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "Confirmation:"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "import_online_skill"

    Req.Test.expect(__MODULE__, &detail_response/1)

    approve_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["approve", pending["id"], "--reason", "import smoke"])
      end)

    assert approve_output =~ "#{pending["id"]} status=approved"
    assert approve_output =~ "Imported target:"
    assert approve_output =~ "Manifest:"
  end

  test "online search approval output explains source failures" do
    put_online_policy!()

    search_output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["search-online", "memory"])
      end)

    assert search_output =~ "Status: needs_confirmation"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "search_online_skills"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search"

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(404, "<html>not found</html>")
    end)

    approve_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["approve", pending["id"], "--reason", "search smoke"])
      end)

    assert approve_output =~ "#{pending["id"]} status=approved"
    assert approve_output =~ "Result status: failed"
    assert approve_output =~ "Failure: online_skill_source_http_error: 404"

    resolved_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["list", "--resolved"])
      end)

    assert resolved_output =~ "#{pending["id"]} status=approved"
    assert resolved_output =~ "Failure: online_skill_source_http_error: 404"
  end

  test "direct remote import task creates confirmation and approval imports disabled skill" do
    put_direct_import_policy!()

    output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["import-url", "https://example.com/skills/demo/SKILL.md"])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "URL: https://example.com/skills/demo/SKILL.md"
    assert output =~ "Confirmation:"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "import_remote_skill"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/skills/demo/SKILL.md"

      conn
      |> Plug.Conn.put_resp_content_type("text/markdown")
      |> Plug.Conn.send_resp(200, online_skill_md())
    end)

    approve_output =
      capture_io(fn ->
        assert :ok =
                 ConfirmationsTask.run(["approve", pending["id"], "--reason", "direct import"])
      end)

    assert approve_output =~ "#{pending["id"]} status=approved"
    assert approve_output =~ "Imported target:"
    assert approve_output =~ "Manifest:"
  end

  test "local import task creates confirmation and approval imports disabled skill", %{root: root} do
    skill_root = write_import_skill!(root, "local-import")

    output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["import-local", skill_root])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "Path: #{Path.expand(skill_root)}"
    assert output =~ "Confirmation:"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "import_local_skill"

    approve_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["approve", pending["id"], "--reason", "local import"])
      end)

    assert approve_output =~ "#{pending["id"]} status=approved"
    assert approve_output =~ "Imported target:"
    assert approve_output =~ "Manifest:"
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp write_script_skill!(home, name) do
    skill_root = Path.join([home, "skills", name])
    script_path = Path.join([skill_root, "scripts", "hello"])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(Path.join(skill_root, "SKILL.md"), skill_markdown(name))
    File.write!(script_path, "#!/bin/sh\nprintf 'hello from #{name}\\n'\n")
    File.chmod!(script_path, 0o755)
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

    Run only through Allbert.
    """
  end

  defp put_script_policy!(workspace) do
    settings = %{
      "permissions" => %{"skill_script_execute" => "allowed"},
      "execution" => %{
        "local" => %{"allowed_roots" => [workspace]},
        "skill_scripts" => %{"enabled" => true}
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp put_online_policy! do
    settings = %{
      "permissions" => %{
        "online_skill_import" => "allowed",
        "external_network" => "allowed"
      },
      "skills" => %{
        "online_import" => %{
          "enabled" => true,
          "allowed_sources" => ["skills_sh"],
          "sources" => %{"skills_sh" => %{"enabled" => true}}
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp put_direct_import_policy! do
    settings = %{
      "permissions" => %{
        "online_skill_import" => "allowed",
        "external_network" => "allowed"
      },
      "external_services" => %{
        "enabled" => true,
        "allowed_hosts" => ["example.com"],
        "allowed_paths" => ["/skills/"],
        "allowed_methods" => ["GET"],
        "max_response_bytes" => 262_144
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp write_import_skill!(root, name) do
    skill_root = Path.join([root, "imports", name])
    File.mkdir_p!(Path.join(skill_root, "references"))
    File.write!(Path.join(skill_root, "SKILL.md"), online_skill_md())
    File.write!(Path.join(skill_root, "references/notes.md"), "local notes")
    skill_root
  end

  defp detail_response(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "id" => "vercel-labs/skills/find-skills",
        "name" => "find-skills",
        "owner" => "vercel-labs",
        "repository" => "skills",
        "description" => "Find skills.",
        "files" => %{"SKILL.md" => online_skill_md()}
      })
    )
  end

  defp online_skill_md do
    """
    ---
    name: find-skills
    description: Find skills.
    ---

    Search the registry.
    """
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
