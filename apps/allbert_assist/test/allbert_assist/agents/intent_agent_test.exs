defmodule AllbertAssist.Agents.IntentAgentTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
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
    Settings.put("workspace.signal_bridge.log_dropped_fragments", false, %{audit?: false})

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
      "doctor_model_profile",
      "doctor_voice_provider",
      "set_active_model_profile",
      "generate_image",
      "synthesize_voice",
      "list_channels",
      "show_channel",
      "list_apps",
      "show_app",
      "list_plugins",
      "show_plugin",
      "get_public_call_result",
      "resume_thread_on_channel",
      "preview_plan",
      "open_calendar_panel",
      "open_mail_panel",
      "open_github_panel"
    ]

    browser_actions = [
      "browser_research_handoff"
    ]

    stocksage_actions = [
      "list_analyses",
      "show_analysis",
      "get_trends",
      "queue_analysis",
      "run_analysis"
    ]

    notes_files_actions = [
      "search_notes",
      "read_note",
      "write_note"
    ]

    allowed_action_sets =
      [
        core_actions,
        core_actions ++ browser_actions,
        core_actions ++ notes_files_actions,
        core_actions ++ browser_actions ++ notes_files_actions,
        core_actions ++ stocksage_actions,
        core_actions ++ browser_actions ++ stocksage_actions,
        core_actions ++ notes_files_actions ++ stocksage_actions,
        core_actions ++ browser_actions ++ notes_files_actions ++ stocksage_actions
      ]
      |> Enum.map(&MapSet.new/1)

    assert MapSet.new(action_names) in allowed_action_sets
  end

  test "routes tool discovery prompts to internal find_tools action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "what tools do I have for working with settings?",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               thread_id: "thr-tool-discovery",
               session_id: "sess-tool-discovery",
               input_signal_id: "sig-tool-discovery"
             })

    assert response.status == :completed
    assert response.decision.intent == :find_tools
    assert response.decision.selected_action == "find_tools"
    assert response.message =~ "tool candidate"
    assert Enum.any?(response.actions, &(&1.name == "find_tools"))

    assert {:ok, server_response} =
             IntentAgent.respond(%{
               text: "find me an MCP server for github",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               thread_id: "thr-tool-server-discovery",
               session_id: "sess-tool-server-discovery",
               input_signal_id: "sig-tool-server-discovery"
             })

    assert server_response.status == :completed
    assert server_response.decision.intent == :find_tools
    assert server_response.decision.selected_action == "find_tools"
  end

  test "routes documented Plan/Build intent corpus", %{root: root} do
    copy_workflow_fixture!("multi_step", root)

    assert {:ok, preview_response} =
             IntentAgent.respond(%{
               text: "plan: collect issues and summarize them",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               input_signal_id: "sig-plan-preview"
             })

    assert preview_response.status == :advisory
    assert preview_response.decision.selected_action == "preview_plan"
    assert preview_response.output_data.preview.workflow_id == "ad_hoc_plan"

    for text <- ["run workflow multi_step", "run multi_step"] do
      assert {:ok, run_response} =
               IntentAgent.respond(%{
                 text: text,
                 channel: :test,
                 user_id: "local",
                 operator_id: "local",
                 input_signal_id: "sig-#{String.replace(text, " ", "-")}"
               })

      assert run_response.status == :needs_confirmation
      assert run_response.decision.selected_action == "start_plan_run"
      assert [%{name: "start_plan_run"}] = run_response.actions
    end

    assert {:ok, list_workflows_response} =
             IntentAgent.respond(%{
               text: "list workflows",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               input_signal_id: "sig-list-workflows"
             })

    assert list_workflows_response.status == :completed
    assert list_workflows_response.decision.selected_action == "list_workflows"
  end

  test "neutral app descriptor returns handoff response without running the app action" do
    with_stocksage_registered(fn ->
      assert {:ok, response} =
               IntentAgent.respond(%{
                 text: "analyze CIEN",
                 channel: :test,
                 user_id: "local",
                 operator_id: "local",
                 thread_id: "thr-intent-handoff",
                 session_id: "sess-intent-handoff",
                 active_app: :allbert,
                 input_signal_id: "sig-intent-handoff"
               })

      # v0.54 (ADR 0060): the app-handoff is no longer an inert dead-end — it is
      # rendered as a channel-answerable clarification (no app action is run), and
      # the intent_handoff metadata is preserved for the web canvas surface.
      assert response.status == :needs_clarification
      assert response.decision.intent == :app_handoff
      assert response.decision.active_app == :allbert
      assert response.intent_handoff.app_id == :stocksage
      assert response.intent_handoff.action_name == "run_analysis"
      assert response.intent_handoff.extracted_slots == %{"ticker" => "CIEN"}
      refute response.approval_handoff
      refute Enum.any?(response.actions, &Map.has_key?(&1, :confirmation_id))
    end)
  end

  test "neutral app descriptor with missing slot returns clarification response" do
    with_stocksage_registered(fn ->
      assert {:ok, response} =
               IntentAgent.respond(%{
                 text: "analyze",
                 channel: :test,
                 user_id: "local",
                 operator_id: "local",
                 thread_id: "thr-intent-clarify",
                 session_id: "sess-intent-clarify",
                 active_app: :allbert,
                 input_signal_id: "sig-intent-clarify"
               })

      assert response.status == :needs_clarification
      assert response.decision.intent == :clarify_intent
      assert response.message =~ "Which ticker"
      assert response.intent_handoff.missing_slots == ["ticker"]
      refute Enum.any?(response.actions, &Map.has_key?(&1, :confirmation_id))
    end)
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

    assert {:ok, generic_update} =
             IntentAgent.respond(%{
               text: "Set workspace.theme to dark",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-generic-setting"
             })

    assert generic_update.status == :completed
    assert generic_update.message =~ "Updated workspace.theme.mode"
    assert [%{name: "update_setting"}] = generic_update.actions
    assert {:ok, "dark"} = Settings.get("workspace.theme.mode")

    assert {:ok, read_only_update} =
             IntentAgent.respond(%{
               text: "Set workspace.mobile.breakpoint_px to 900",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-read-only-setting"
             })

    assert read_only_update.status == :denied
    assert read_only_update.message =~ "read_only_setting"
    assert [%{name: "update_setting"}] = read_only_update.actions

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

    assert {:ok, dotted_refused} =
             IntentAgent.respond(%{
               text: "Set providers.openai.api_key_ref to sk-test",
               channel: :test,
               operator_id: "local",
               input_signal_id: "sig-provider-key-ref"
             })

    assert dotted_refused.status == :denied
    assert dotted_refused.message =~ "will not store provider credentials"
    refute dotted_refused.message =~ "sk-test"
    assert [%{name: "set_provider_credential"}] = dotted_refused.actions
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
    assert response.message =~ "read-only capabilities"
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

  test "does not treat scheduled job prose that starts with run as shell execution" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Run from browser validation.",
               channel: :job,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.decision.selected_action == "direct_answer"

    assert [%{name: "direct_answer", permission_decision: %{decision: :allowed}}] =
             response.actions

    assert {:ok, shell_response} =
             IntentAgent.respond(%{
               text: "shell pwd",
               channel: :job,
               operator_id: "local"
             })

    assert shell_response.status == :denied
    assert shell_response.decision.selected_action == "run_shell_command"

    assert [%{name: "run_shell_command", permission_decision: %{decision: :denied}}] =
             shell_response.actions
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

  test "routes MCP resource URI requests to MCP read action" do
    assert {:ok, mcp_response} =
             IntentAgent.respond(%{
               text: "Read mcp://local-server/resources/doc",
               channel: :test,
               operator_id: "local"
             })

    assert mcp_response.decision.selected_action == "mcp_read_resource"
    assert mcp_response.decision.intent == :mcp_read_resource

    assert mcp_response.decision.trace_metadata.intent_candidates.selected.action_name ==
             "mcp_read_resource"

    assert [%{operation_class: :mcp_resource_read, unsupported?: false}] =
             mcp_response.decision.trace_metadata.intent_candidates.selected.resource_access
  end

  test "routes MCP tool phrasing to MCP discovery action" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "List the tools on my demo MCP server",
               channel: :test,
               operator_id: "local"
             })

    assert response.decision.selected_action == "mcp_list_tools"
    assert response.decision.intent == :mcp_list_tools
    assert get_in(response.decision.trace_metadata, [:extracted_slots, :server_id]) == "demo"
  end

  test "routes agent URI requests to unsupported resource workflow" do
    assert {:ok, agent_response} =
             IntentAgent.respond(%{
               text: "Delegate this to agent+https://agent.example/tasks/review",
               channel: :test,
               operator_id: "local"
             })

    assert agent_response.status == :unsupported
    assert agent_response.message =~ "future agent endpoints"
    assert [%{workflow: :unsupported_uri_scheme}] = agent_response.actions
  end

  test "skill action plans reject action mismatches before runner invocation" do
    assert {:error, error} = ActionPlan.build("append-memory", "read_recent_memory", %{})

    assert error.code == :action_not_declared_by_skill
    assert error.value == "read_recent_memory"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp with_stocksage_registered(fun) do
    original_plugins = PluginRegistry.registered_plugins()
    original_diagnostics = PluginRegistry.diagnostics()
    app_registered? = AppRegistry.known_app_id?(:stocksage)

    PluginRegistry.clear()
    assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    unless app_registered?, do: assert({:ok, :stocksage} = AppRegistry.register(StockSage.App))

    try do
      fun.()
    after
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      unless app_registered?, do: AppRegistry.unregister(:stocksage)

      Enum.each(original_diagnostics, fn {plugin_id, diagnostics} ->
        PluginRegistry.put_diagnostics(plugin_id, diagnostics)
      end)
    end
  end

  defp copy_workflow_fixture!(id, root) do
    workflows = Path.join(root, "workflows")
    File.mkdir_p!(workflows)

    File.cp!(
      Path.expand("../../fixtures/v0.44/workflows/#{id}.yaml", __DIR__),
      Path.join(workflows, "#{id}.yaml")
    )
  end

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
