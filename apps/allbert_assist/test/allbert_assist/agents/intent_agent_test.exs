defmodule AllbertAssist.Agents.IntentAgentTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.ActionPlan

  setup do
    original_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_audit_config = Application.get_env(:allbert_assist, Audit)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-intent-memory-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Audit, root: Path.join(root, "execution"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    configure_external()

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Memory, original_config)
      else
        Application.delete_env(:allbert_assist, Memory)
      end

      if original_settings_config do
        Application.put_env(:allbert_assist, Settings, original_settings_config)
      else
        Application.delete_env(:allbert_assist, Settings)
      end

      restore_env(Audit, original_audit_config)
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "defines the agent action surface as Jido action modules" do
    assert IntentAgent.action_modules() == Registry.agent_modules()

    action_names = Enum.map(IntentAgent.action_modules(), & &1.name())

    core_actions = [
      "direct_answer",
      "append_memory",
      "read_recent_memory",
      "list_skills",
      "read_skill",
      "activate_skill",
      "plan_shell_command",
      "run_shell_command",
      "unsupported_resource_workflow",
      "external_network_request",
      "plan_package_install",
      "search_online_skills",
      "show_online_skill",
      "list_settings",
      "read_setting",
      "update_setting",
      "explain_setting",
      "list_provider_profiles",
      "list_model_profiles",
      "set_provider_credential",
      "list_channels",
      "show_channel",
      "list_apps",
      "show_app",
      "list_plugins",
      "show_plugin"
    ]

    stocksage_actions = [
      "list_analyses",
      "show_analysis",
      "get_trends",
      "queue_analysis"
    ]

    assert action_names in [core_actions, core_actions ++ stocksage_actions]
  end

  test "routes explicit settings prompts to settings actions" do
    assert {:ok, list_response} =
             IntentAgent.respond(%{
               text: "show settings",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-settings"
             })

    assert list_response.status == :completed
    assert list_response.message =~ "operator.timezone"
    assert [%{name: "list_settings"}] = list_response.actions

    assert {:ok, read_response} =
             IntentAgent.respond(%{
               text: "what is my timezone setting?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-read-setting"
             })

    assert read_response.status == :completed
    assert read_response.message =~ "operator.timezone"
    assert [%{name: "read_setting"}] = read_response.actions
  end

  test "routes safe setting updates and provider credential prompts safely" do
    assert {:ok, update_response} =
             IntentAgent.respond(%{
               text: "set my communication style to balanced",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-update-setting"
             })

    assert update_response.status == :completed
    assert update_response.message =~ "Updated operator.communication_style"
    assert [%{name: "update_setting"}] = update_response.actions

    assert {:ok, guidance} =
             IntentAgent.respond(%{
               text: "configure my OpenAI API key",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-provider-key"
             })

    assert guidance.status == :completed
    assert guidance.message =~ "explicit CLI or LiveView secret form"

    assert {:ok, refused} =
             IntentAgent.respond(%{
               text: "set my OpenAI API key to test-key",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-provider-key-raw"
             })

    assert refused.status == :denied
    assert refused.message =~ "will not store provider credentials"
  end

  test "answers capability prompts with safe v0.01 capabilities" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Hello Allbert. What can you do right now?",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "direct-answer"
    assert response.message =~ "append-memory"
    assert response.message =~ "plan-shell-command"
    assert response.message =~ "I cannot execute shell commands"
    assert [%{name: "list_skills"}] = response.actions
    assert response.runner_metadata.selected_skill == "list-skills"
  end

  test "routes skill inspection prompts to the read-only list action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "List the skills you can inspect.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "v0.01-safe capabilities"
    assert [%{name: "list_skills", permission_decision: %{decision: :allowed}}] = response.actions
    assert response.runner_metadata.selected_skill == "list-skills"
  end

  test "routes available-skills questions to the registry-backed list action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "What skills are available?",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "append-memory"
    assert [%{name: "list_skills", permission_decision: %{decision: :allowed}}] = response.actions
    assert response.runner_metadata.selected_skill == "list-skills"
  end

  test "routes activation prompts to the read-only activate action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Activate skill append-memory",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "## Skill Context"
    assert response.message =~ "append-memory"

    assert [%{name: "activate_skill", permission_decision: %{decision: :allowed}}] =
             response.actions
  end

  test "answers plain prompts without selecting a side-effect action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Hello Allbert.",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "side-effect-free"
    assert response.runner_metadata.action_name == "direct_answer"
    assert response.runner_metadata.action_module == AllbertAssist.Actions.Intent.DirectAnswer
    assert response.runner_metadata.selected_skill == "direct-answer"
    assert is_binary(response.runner_metadata.requested_signal_id)
    assert is_binary(response.runner_metadata.completed_signal_id)

    assert [
             %{
               name: "direct_answer",
               permission: :read_only,
               permission_decision: %{decision: :allowed},
               runner_metadata: %{action_name: "direct_answer", selected_skill: "direct-answer"}
             }
           ] = response.actions
  end

  test "writes markdown memory for explicit memory requests", %{root: root} do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Remember that I prefer short implementation updates.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-123"
             })

    assert response.status == :completed
    assert response.message =~ "Saved markdown memory"
    assert response.message =~ "I prefer short implementation updates."
    assert response.memory.path =~ Path.join(root, "preferences")
    assert File.exists?(response.memory.path)

    assert [
             %{
               name: "append_memory",
               status: :completed,
               durable: true,
               permission_decision: %{decision: :allowed},
               runner_metadata: %{selected_skill: "append-memory"}
             }
           ] = response.actions
  end

  test "reads markdown memory for recall requests" do
    assert {:ok, _response} =
             IntentAgent.respond(%{
               text: "Remember that my planning docs should be implementation-ready.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-123"
             })

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "What do you remember about my planning docs?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-456"
             })

    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert response.message =~ "planning docs should be implementation-ready"

    assert [
             %{
               name: "read_recent_memory",
               memory_count: 1,
               runner_metadata: %{selected_skill: "read-recent-memory"}
             }
           ] = response.actions
  end

  test "captures low-risk personal identity statements as preference memory", %{root: root} do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "my name is Sandeep",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-name"
             })

    assert response.status == :completed
    assert response.message =~ "Saved markdown memory"
    assert response.memory.path =~ Path.join(root, "preferences")
    assert response.memory.body =~ "Heuristic family: identity.name"
    assert response.memory.body =~ "Preferred name: Sandeep"
    assert File.exists?(response.memory.path)

    assert [
             %{
               name: "append_memory",
               memory_category: :preferences,
               permission_decision: %{decision: :allowed},
               runner_metadata: %{selected_skill: "append-memory"}
             }
           ] = response.actions
  end

  test "recalls personal identity from markdown memory" do
    assert {:ok, _response} =
             IntentAgent.respond(%{
               text: "my name is Sandeep",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-name"
             })

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "what is my name?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-name-recall"
             })

    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert response.message =~ "Preferred name: Sandeep"

    assert [
             %{
               name: "read_recent_memory",
               memory_count: 1,
               input: %{query: query},
               runner_metadata: %{selected_skill: "read-recent-memory"}
             }
           ] = response.actions

    assert query =~ "preferred name"
  end

  test "captures and recalls communication preferences" do
    assert {:ok, write_response} =
             IntentAgent.respond(%{
               text: "I prefer short implementation updates.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-preference"
             })

    assert write_response.status == :completed
    assert write_response.memory.category == :preferences
    assert write_response.memory.body =~ "Heuristic family: local_context.preference"

    assert {:ok, read_response} =
             IntentAgent.respond(%{
               text: "how should you update me?",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-preference-recall"
             })

    assert read_response.status == :completed
    assert read_response.message =~ "short implementation updates"

    assert [
             %{
               name: "read_recent_memory",
               memory_count: 1,
               input: %{query: query},
               runner_metadata: %{selected_skill: "read-recent-memory"}
             }
           ] = read_response.actions

    assert query =~ "preference communication update"
  end

  test "does not silently store sensitive personal data without explicit memory intent", %{
    root: root
  } do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "I prefer my password to be hunter2.",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-sensitive"
             })

    assert response.status == :completed
    assert response.message =~ "side-effect-free"
    assert [%{name: "direct_answer"}] = response.actions
    assert response.runner_metadata.selected_skill == "direct-answer"
    assert [] = Path.wildcard(Path.join([root, "**", "*.md"]))
  end

  test "refuses command execution through the confirmed shell action by default" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Run rm -rf /tmp/example",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert response.message =~ "Shell command execution was denied"

    assert [
             %{
               name: "run_shell_command",
               status: :denied,
               execution: :not_started,
               permission_decision: %{decision: :denied},
               denial_reason: :local_execution_disabled
             }
           ] = response.actions
  end

  test "requires confirmation for external network requests" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Fetch https://example.com from the internet",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "External network request is ready"

    assert [
             %{
               name: "external_network_request",
               execution: :pending_confirmation,
               permission_decision: %{decision: :needs_confirmation},
               confirmation_id: confirmation_id,
               runner_metadata: %{selected_skill: "external-network-request"}
             }
           ] = response.actions

    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["origin"]["channel"] == "test"
    assert pending["selected_skill"]["name"] == "external-network-request"
    assert pending["target_execution_mode"] == "req_http"
  end

  test "routes URL summarization to confirmed fetch before summarizer handoff" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Check https://example.com/report and summarize it for me",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "External network request is ready"
    assert response.message =~ "Operation: summarize_url"
    assert response.decision.intent == :summarize_url
    assert response.decision.selected_skill == "external-network-request"

    assert [
             %{
               name: "external_network_request",
               status: :needs_confirmation,
               execution: :pending_confirmation,
               confirmation_id: confirmation_id,
               runner_metadata: %{selected_skill: "external-network-request"}
             }
           ] = response.actions

    assert [%{operation_class: :summarize_url, downstream_consumer: :url_summarizer}] =
             response.resource_access

    assert [
             %{operation_class: :summarize_url, downstream_consumer: :url_summarizer}
           ] = response.decision.trace_metadata.intent_candidates.selected.resource_access

    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["params_summary"]["operation_class"] == "summarize_url"
    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["operation_class"] == "summarize_url"
    assert ref["downstream_consumer"] == "url_summarizer"
  end

  test "routes remote document inspection to confirmed fetch before extractor handoff" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Inspect document https://example.com/report.pdf",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "Operation: inspect_document"
    assert response.decision.intent == :inspect_document

    assert [%{operation_class: :inspect_document, downstream_consumer: :document_extractor}] =
             response.resource_access

    assert [%{confirmation_id: confirmation_id}] = response.actions
    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["params_summary"]["operation_class"] == "inspect_document"
    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["operation_class"] == "inspect_document"
    assert ref["downstream_consumer"] == "document_extractor"
  end

  test "routes generic local file inspection to unavailable file posture without shell fallback" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Read local file ./mix.exs",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :unsupported
    assert response.message =~ "Generic local file inspection is unavailable"
    assert response.message =~ "no shell-command fallback"

    assert [
             %{
               name: "unsupported_resource_workflow",
               status: :unsupported,
               execution: :not_started,
               workflow: :read_local_path
             }
           ] = response.actions

    assert [
             %{
               operation_class: :read_local_path,
               access_mode: :read,
               downstream_consumer: :bounded_file_reader,
               target_action: "unsupported_resource_workflow"
             }
           ] = response.resource_access

    assert Confirmations.list(status: :pending) == []
  end

  test "routes direct remote skill URLs as import_skill posture" do
    put_import_policy!()

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Import skill https://example.com/skills/demo/SKILL.md",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "Nothing has fetched or written yet"
    assert response.decision.intent == :import_skill
    assert response.decision.selected_action == "import_remote_skill"

    assert [
             %{
               operation_class: :import_skill,
               access_mode: :import,
               downstream_consumer: :skill_importer,
               target_action: "import_remote_skill"
             }
           ] = response.resource_access

    assert [%{name: "import_remote_skill", execution: :pending_confirmation}] = response.actions
    assert {:ok, pending} = Confirmations.read(response.confirmation_id)

    assert pending["params_summary"]["resource_refs"] |> hd() |> Map.get("operation_class") ==
             "import_skill"
  end

  test "routes local skill directory imports as import_local_skill posture", %{root: root} do
    put_import_policy!()
    skill_root = Path.join([root, "local-source", "demo-skill"])

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Import skill from #{skill_root}",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "Nothing has read or written yet"
    assert response.decision.intent == :import_local_skill

    assert [
             %{
               operation_class: :import_local_skill,
               access_mode: :import,
               downstream_consumer: :skill_importer,
               target_action: "import_local_skill"
             }
           ] = response.resource_access

    assert [%{name: "import_local_skill", execution: :pending_confirmation}] = response.actions
    refute Enum.any?(response.actions, &(&1.name == "run_skill_script"))
  end

  test "routes package install prompts as package resources instead of shell authority", %{
    root: root
  } do
    put_package_policy!(root)

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "npm install left-pad@1.3.0",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.decision.intent == :plan_package_install
    assert response.decision.selected_action == "plan_package_install"

    assert Enum.any?(response.resource_access, fn access ->
             access.origin_kind == :package_registry &&
               access.resource_uri == "pkg:npm/left-pad@1.3.0" &&
               access.operation_class == :package_install
           end)

    assert Enum.any?(response.resource_access, fn access ->
             access.origin_kind == :local_path &&
               access.operation_class == :package_install &&
               access.downstream_consumer == :package_manager
           end)

    refute Enum.any?(response.actions, &(&1.name == "run_shell_command"))
  end

  test "routes MCP and agent URI requests to unsupported resource workflow" do
    assert {:ok, mcp_response} =
             IntentAgent.respond(%{
               text: "Call mcp://local-server/resources/doc",
               channel: :test,
               operator_id: "local"
             })

    assert mcp_response.status == :unsupported
    assert mcp_response.message =~ "MCP resources and future agent endpoints"
    assert [%{workflow: :unsupported_uri_scheme}] = mcp_response.actions

    assert mcp_response.decision.trace_metadata.intent_candidates.selected.action_name ==
             "unsupported_resource_workflow"

    assert [%{operation_class: :external_service_request, unsupported?: true}] =
             mcp_response.decision.trace_metadata.intent_candidates.selected.resource_access

    assert {:ok, agent_response} =
             IntentAgent.respond(%{
               text: "Delegate this to agent+https://agent.example/tasks/review",
               channel: :test,
               operator_id: "local"
             })

    assert agent_response.status == :unsupported
    assert agent_response.message =~ "does not call MCP tools or delegate"
    assert [%{workflow: :unsupported_uri_scheme}] = agent_response.actions
  end

  test "skill action plans reject action mismatches before runner invocation" do
    assert {:error, error} = ActionPlan.build("append-memory", "read_recent_memory", %{})

    assert error.code == :action_not_declared_by_skill
    assert error.value == "read_recent_memory"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp put_import_policy! do
    assert {:ok, _setting} =
             Settings.put("permissions.online_skill_import", "allowed", %{audit?: false})

    assert {:ok, _setting} = Settings.put("permissions.skill_write", "allowed", %{audit?: false})
  end

  defp put_package_policy!(root) do
    fake_npm = Path.join(root, "fake-npm")
    File.write!(fake_npm, "#!/bin/sh\nprintf 'fake npm %s\\n' \"$*\"\n")
    File.chmod!(fake_npm, 0o755)

    settings = %{
      "permissions" => %{"package_install" => "allowed"},
      "package_installs" => %{
        "enabled" => true,
        "allowed_roots" => [File.cwd!()],
        "allowed_managers" => ["npm"],
        "manager_profiles" => %{"npm" => %{"executable" => fake_npm}}
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end
end
