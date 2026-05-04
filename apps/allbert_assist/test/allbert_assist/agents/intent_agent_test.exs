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

  test "defines the v0.01 action surface as Jido action modules" do
    assert IntentAgent.action_modules() == Registry.agent_modules()

    action_names = Enum.map(IntentAgent.action_modules(), & &1.name())

    assert action_names == [
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
             "set_provider_credential"
           ]
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

  test "routes URL summarization to unsupported resource workflow instead of fetching" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "Check https://example.com/report and summarize it for me",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :unsupported
    assert response.message =~ "URL summarization is deferred to v0.11"
    assert response.message =~ "v0.10 has not run anything"

    assert [
             %{
               name: "unsupported_resource_workflow",
               status: :unsupported,
               execution: :not_started,
               workflow: :summarize_url,
               resource: "https://example.com/report",
               runner_metadata: %{selected_skill: "unsupported-resource-workflow"}
             }
           ] = response.actions

    assert Confirmations.list(status: :pending) == []
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
end
