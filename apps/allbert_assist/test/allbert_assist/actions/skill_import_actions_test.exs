defmodule AllbertAssist.Actions.SkillImportActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills
  alias AllbertAssist.Skills.DirectImport

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_direct_import_config = Application.get_env(:allbert_assist, DirectImport)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-skill-import-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths,
      home: root,
      cache_root: Path.join(root, "cache"),
      skills_root: Path.join(root, "skills")
    )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, DirectImport,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(DirectImport, original_direct_import_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    put_import_policy!()

    {:ok, root: root}
  end

  test "remote URL import creates confirmation before fetching" do
    assert {:ok, response} =
             Runner.run(
               "import_remote_skill",
               %{url: "https://example.com/skills/demo/SKILL.md"},
               context()
             )

    assert response.status == :needs_confirmation
    assert response.message =~ "Nothing has fetched or written yet"

    assert {:ok, pending} = Confirmations.read(response.confirmation_id)
    assert pending["target_action"]["name"] == "import_remote_skill"
    assert pending["target_permission"] == "online_skill_import"

    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["resource_uri"] == "https://example.com/skills/demo/SKILL.md"
    assert ref["operation_class"] == "import_skill"
    assert ref["access_mode"] == "import"
    assert ref["downstream_consumer"] == "skill_importer"
  end

  test "approved remote URL import writes disabled untrusted skill under cache", %{root: root} do
    assert {:ok, pending_response} =
             Runner.run(
               "import_remote_skill",
               %{url: "https://example.com/skills/demo/SKILL.md"},
               context()
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/skills/demo/SKILL.md"

      conn
      |> Plug.Conn.put_resp_content_type("text/markdown")
      |> Plug.Conn.send_resp(200, skill_md("remote-demo"))
    end)

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_response.confirmation_id, reason: "remote import smoke"},
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.status == :completed
    result = approve_response.confirmation["operator_resolution"]["target_result"]
    assert result["status"] == "imported_disabled"
    assert result["enabled?"] == false
    assert result["trusted?"] == false
    assert result["target_root"] =~ Path.join([root, "cache", "skills", "direct_url"])
    assert File.exists?(Path.join(result["target_root"], "SKILL.md"))
    assert File.exists?(result["manifest_path"])

    assert {:ok, skills} = Skills.list()
    refute Enum.any?(skills, &(&1.name == "remote-demo"))
  end

  test "denied remote URL import never fetches or writes", %{root: root} do
    assert {:ok, _setting} =
             Settings.put("permissions.online_skill_import", "denied", %{audit?: false})

    assert {:ok, response} =
             Runner.run(
               "import_remote_skill",
               %{url: "https://example.com/skills/demo/SKILL.md"},
               context()
             )

    assert response.status == :denied
    assert Confirmations.list(status: :pending) == []
    refute File.exists?(Path.join([root, "cache", "skills", "direct_url"]))
  end

  test "remote import grant does not authorize generic external network requests" do
    assert {:ok, pending_response} =
             Runner.run(
               "import_remote_skill",
               %{url: "https://example.com/skills/demo/SKILL.md"},
               context()
             )

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/markdown")
      |> Plug.Conn.send_resp(200, skill_md("remote-demo"))
    end)

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{
                 id: pending_response.confirmation_id,
                 reason: "remember direct remote import",
                 remember_scope: "exact"
               },
               %{actor: "local", channel: :cli}
             )

    assert [remembered] =
             approve_response.confirmation["operator_resolution"]["remembered_grants"]

    assert remembered["operation_class"] == "import_skill"

    assert {:ok, external_response} =
             Runner.run(
               "external_network_request",
               %{url: "https://example.com/skills/demo/SKILL.md"},
               context()
             )

    assert external_response.status == :needs_confirmation
    assert external_response.confirmation_id != nil
  end

  test "local directory import creates confirmation before reading imported content", %{
    root: root
  } do
    skill_root = write_local_skill!(root, "local-demo")

    assert {:ok, response} =
             Runner.run("import_local_skill", %{path: skill_root}, context())

    assert response.status == :needs_confirmation
    assert response.message =~ "Nothing has read or written yet"

    assert {:ok, pending} = Confirmations.read(response.confirmation_id)
    assert pending["target_action"]["name"] == "import_local_skill"
    assert pending["target_permission"] == "skill_write"

    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["resource_uri"] =~ "file://"
    assert ref["operation_class"] == "import_local_skill"
    assert ref["access_mode"] == "import"
    assert ref["downstream_consumer"] == "skill_importer"
  end

  test "approved local directory import writes disabled untrusted skill", %{root: root} do
    skill_root = write_local_skill!(root, "local-demo")

    assert {:ok, pending_response} =
             Runner.run("import_local_skill", %{path: skill_root}, context())

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_response.confirmation_id, reason: "local import smoke"},
               %{actor: "local", channel: :cli}
             )

    result = approve_response.confirmation["operator_resolution"]["target_result"]
    assert result["status"] == "imported_disabled"
    assert result["enabled?"] == false
    assert result["trusted?"] == false
    assert File.exists?(Path.join(result["target_root"], "SKILL.md"))
    assert File.exists?(Path.join(result["target_root"], "references/notes.md"))
  end

  test "local directory import rejects symlink escapes after approval", %{root: root} do
    skill_root = write_local_skill!(root, "local-demo")
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.md"), "secret")
    assert :ok = File.ln_s(outside, Path.join([skill_root, "references", "outside"]))

    assert {:ok, pending_response} =
             Runner.run("import_local_skill", %{path: skill_root}, context())

    assert {:ok, approve_response} =
             Runner.run("approve_confirmation", %{id: pending_response.confirmation_id}, %{
               actor: "local",
               channel: :cli
             })

    result = approve_response.confirmation["operator_resolution"]["target_result"]
    assert result["status"] == "failed"
    assert result["failure_reason"]["code"] == "unsafe_local_skill_symlink"
  end

  defp context do
    %{
      actor: "local",
      channel: :cli,
      surface: "mix allbert.skills",
      request: %{operator_id: "local", channel: :cli, input_signal_id: "sig-import"}
    }
  end

  defp put_import_policy! do
    settings = %{
      "permissions" => %{
        "external_network" => "allowed",
        "online_skill_import" => "allowed",
        "skill_write" => "allowed"
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

  defp write_local_skill!(root, name) do
    skill_root = Path.join([root, "local-source", name])
    File.mkdir_p!(Path.join(skill_root, "references"))
    File.write!(Path.join(skill_root, "SKILL.md"), skill_md(name))
    File.write!(Path.join(skill_root, "references/notes.md"), "local notes")
    skill_root
  end

  defp skill_md(name) do
    """
    ---
    name: #{name}
    description: #{name} imported test skill.
    ---

    Review this skill before activation.
    """
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
