defmodule AllbertAssist.Actions.OnlineSkillActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills
  alias AllbertAssist.Skills.Online.RegistryClient

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_client_config = Application.get_env(:allbert_assist, RegistryClient)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-online-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths,
      home: root,
      cache_root: Path.join(root, "cache"),
      skills_root: Path.join(root, "skills")
    )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, RegistryClient,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      restore_env(RegistryClient, original_client_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    put_online_policy!()

    {:ok, root: root}
  end

  test "search creates confirmation and approval fetches results" do
    assert {:ok, pending_response} =
             Runner.run(
               "search_online_skills",
               %{query: "find skills", source: "skills_sh"},
               context()
             )

    assert pending_response.status == :needs_confirmation
    assert pending_response.confirmation_id =~ "conf_"

    assert {:ok, pending} = Confirmations.read(pending_response.confirmation_id)
    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["origin_kind"] == "remote_source"
    assert ref["operation_class"] == "online_skill_search"
    assert ref["access_mode"] == "fetch"
    assert ref["scope"] == %{"kind" => "source_profile", "value" => "skills_sh"}

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"skills" => [skill_json()]}))
    end)

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_response.confirmation_id, reason: "search smoke"},
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "approved"
    result = approve_response.confirmation["operator_resolution"]["target_result"]
    assert [candidate] = result["results"]
    assert candidate["id"] == "vercel-labs/skills/find-skills"
  end

  test "remembered source-profile grant lets later search run without confirmation" do
    assert {:ok, pending_response} =
             Runner.run(
               "search_online_skills",
               %{query: "find skills", source: "skills_sh"},
               context()
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"skills" => [skill_json()]}))
    end)

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{
                 id: pending_response.confirmation_id,
                 reason: "remember online search source",
                 remember_scope: "exact"
               },
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.confirmation["status"] == "approved"

    assert [remembered] =
             approve_response.confirmation["operator_resolution"]["remembered_grants"]

    assert remembered["operation_class"] == "online_skill_search"
    assert remembered["scope"]["kind"] == "source_profile"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"skills" => [skill_json()]}))
    end)

    assert {:ok, reused_response} =
             Runner.run(
               "search_online_skills",
               %{query: "memory", source: "skills_sh"},
               context()
             )

    assert reused_response.status == :completed
    assert reused_response.actions |> hd() |> get_in([:resource_grants, :applied?])
    assert reused_response.actions |> hd() |> get_in([:target_resumed?]) == false
    assert Confirmations.list(status: :pending) == []
  end

  test "search approval stays approved when the online source fails" do
    assert {:ok, pending_response} =
             Runner.run(
               "search_online_skills",
               %{query: "memory", source: "skills_sh"},
               context()
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/search"

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(404, "<html>not found</html>")
    end)

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_response.confirmation_id, reason: "search smoke"},
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "approved"

    resolution = approve_response.confirmation["operator_resolution"]
    assert resolution["target_resumed?"]
    assert resolution["target_status"] == "failed"

    result = resolution["target_result"]
    assert result["status"] == "failed"
    assert result["failure_reason"]["code"] == "online_skill_source_http_error"
    assert result["failure_reason"]["detail"] == "404"
    assert result["source"]["id"] == "skills_sh"
  end

  test "show creates detail confirmation with resource refs and approval fetches detail" do
    assert {:ok, pending_response} =
             Runner.run("show_online_skill", %{source: "skills_sh", id: source_id()}, context())

    assert pending_response.status == :needs_confirmation
    assert {:ok, pending} = Confirmations.read(pending_response.confirmation_id)
    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["origin_kind"] == "remote_source"
    assert ref["operation_class"] == "online_skill_detail"
    assert ref["access_mode"] == "fetch"

    Req.Test.expect(__MODULE__, &detail_response/1)

    assert {:ok, approve_response} =
             Runner.run("approve_confirmation", %{id: pending_response.confirmation_id}, %{
               actor: "local",
               channel: :cli
             })

    detail = approve_response.confirmation["operator_resolution"]["target_result"]
    assert detail["id"] == source_id()
    assert [result_ref] = detail["resource_refs"]
    assert result_ref["operation_class"] == "online_skill_detail"
  end

  test "audit creates confirmation and approval reports import eligibility" do
    assert {:ok, pending_response} =
             Runner.run("audit_online_skill", %{source: "skills_sh", id: source_id()}, context())

    Req.Test.expect(__MODULE__, &detail_response/1)

    assert {:ok, approve_response} =
             Runner.run("approve_confirmation", %{id: pending_response.confirmation_id}, %{
               actor: "local",
               channel: :cli
             })

    audit = approve_response.confirmation["operator_resolution"]["target_result"]
    assert audit["status"] == "passed"
    assert audit["import_eligible?"]
    assert "scripts_present" in audit["warnings"]
  end

  test "import approval writes disabled untrusted skill under cache", %{root: root} do
    assert {:ok, pending_response} =
             Runner.run("import_online_skill", %{source: "skills_sh", id: source_id()}, context())

    assert Confirmations.list(status: :pending) |> length() == 1
    assert {:ok, pending} = Confirmations.read(pending_response.confirmation_id)
    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["origin_kind"] == "remote_source"
    assert ref["operation_class"] == "online_skill_import"
    assert ref["access_mode"] == "import"

    Req.Test.expect(__MODULE__, &detail_response/1)

    assert {:ok, approve_response} =
             Runner.run("approve_confirmation", %{id: pending_response.confirmation_id}, %{
               actor: "local",
               channel: :cli
             })

    assert approve_response.confirmation["status"] == "approved"

    result = approve_response.confirmation["operator_resolution"]["target_result"]
    assert result["status"] == "imported_disabled"
    assert result["enabled?"] == false
    assert result["trusted?"] == false
    assert result["target_root"] =~ Path.join([root, "cache", "skills", "skills_sh"])
    assert File.exists?(Path.join(result["target_root"], "SKILL.md"))
    assert File.exists?(result["manifest_path"])

    assert {:ok, skills} = Skills.list()
    refute Enum.any?(skills, &(&1.name == "find-skills"))
    assert {:ok, diagnostics} = Skills.diagnostics()
    assert Enum.any?(diagnostics, &(&1.code == :imported_skill_disabled))

    assert {:ok, enabled} = Settings.get("skills.enabled")
    assert enabled == []
  end

  test "remembered import grant lets later online import run without confirmation" do
    assert {:ok, pending_response} =
             Runner.run("import_online_skill", %{source: "skills_sh", id: source_id()}, context())

    Req.Test.expect(__MODULE__, &detail_response/1)

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{
                 id: pending_response.confirmation_id,
                 reason: "remember online import",
                 remember_scope: "exact"
               },
               %{actor: "local", channel: :cli}
             )

    assert approve_response.confirmation["status"] == "approved"

    assert [remembered] =
             approve_response.confirmation["operator_resolution"]["remembered_grants"]

    assert remembered["operation_class"] == "online_skill_import"
    assert remembered["scope"]["kind"] == "source_profile"

    Req.Test.expect(__MODULE__, &detail_response/1)

    assert {:ok, reused_response} =
             Runner.run("import_online_skill", %{source: "skills_sh", id: source_id()}, context())

    assert reused_response.status == :completed
    assert reused_response.online_skill_import.status == :imported_disabled
    assert reused_response.actions |> hd() |> get_in([:resource_grants, :applied?])
    assert reused_response.actions |> hd() |> get_in([:target_resumed?]) == false
    assert Confirmations.list(status: :pending) == []
  end

  test "online import disabled denies without creating confirmation" do
    assert {:ok, _setting} =
             Settings.put("skills.online_import.enabled", false, %{audit?: false})

    assert {:ok, response} =
             Runner.run("import_online_skill", %{source: "skills_sh", id: source_id()}, context())

    assert response.status == :denied
    assert response.actions |> hd() |> Map.fetch!(:denial_reason) == :online_skill_import_disabled
    assert Confirmations.list(status: :pending) == []
  end

  defp context do
    %{
      actor: "local",
      channel: :cli,
      surface: "mix allbert.skills",
      request: %{operator_id: "local", channel: :cli, input_signal_id: "sig-online"}
    }
  end

  defp put_online_policy! do
    settings = %{
      "permissions" => %{
        "external_network" => "allowed",
        "online_skill_import" => "allowed"
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

  defp source_id, do: "vercel-labs/skills/find-skills"

  defp detail_response(conn) do
    assert conn.request_path == "/api/skills/vercel-labs%2Fskills%2Ffind-skills"

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(detail_json()))
  end

  defp skill_json do
    %{
      "id" => source_id(),
      "name" => "find-skills",
      "owner" => "vercel-labs",
      "repository" => "skills",
      "description" => "Find skills from the registry."
    }
  end

  defp detail_json do
    Map.put(skill_json(), "files", %{
      "SKILL.md" => skill_md(),
      "scripts/search.js" => "console.log('search');"
    })
  end

  defp skill_md do
    """
    ---
    name: find-skills
    description: Find skills from the registry.
    ---

    Search the registry.
    """
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
