defmodule AllbertAssist.RuntimeIntentAgentTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings

  setup do
    original_config = Application.get_env(:allbert_assist, Runtime)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_audit_config = Application.get_env(:allbert_assist, Audit)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-runtime-memory-test-#{System.unique_integer([:positive])}"
      )

    Application.delete_env(:allbert_assist, Runtime)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Audit, root: Path.join(root, "execution"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    configure_external()

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Runtime, original_config)
      else
        Application.delete_env(:allbert_assist, Runtime)
      end

      if original_memory_config do
        Application.put_env(:allbert_assist, Memory, original_memory_config)
      else
        Application.delete_env(:allbert_assist, Memory)
      end

      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Audit, original_audit_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "default runtime uses the primary intent agent" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Hello Allbert. What can you do right now?",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "read-only capabilities"
    assert [%{name: "list_skills"}] = response.actions
    assert response.decision.trace_metadata.intent_candidates.selected.id == "list_skills"
  end

  test "default runtime can return inert registered surface navigation" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Open Allbert chat",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message == "Open Allbert Workspace: /agent"
    assert response.actions == []
    assert response.decision.intent == :open_surface
    assert Map.get(response.decision, :selected_action) == nil
    assert response.decision.trace_metadata.surface_target.path == "/agent"
  end

  test "default runtime routes generic setting-shaped prompts to update_setting" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Set workspace.theme to dark",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "Updated workspace.theme"
    assert response.decision.selected_action == "update_setting"
    assert response.decision.trace_metadata.intent_candidates.selected.id == "update_setting"
    assert [%{name: "update_setting"}] = response.actions
    assert {:ok, "dark"} = Settings.get("workspace.theme")
  end

  test "default runtime refuses generic secret-shaped setting prompts without echoing value" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Set providers.openai.api_key_ref to sk-test",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert response.message =~ "will not store provider credentials"
    refute response.message =~ "sk-test"
    assert response.decision.selected_action == "set_provider_credential"
    assert [%{name: "set_provider_credential"}] = response.actions
  end

  test "default runtime refuses command execution" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Run rm -rf /tmp/example",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert response.message =~ "Shell command execution was denied"
    assert [%{name: "run_shell_command", execution: :not_started}] = response.actions
  end

  test "default runtime requires confirmation for external network requests" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Fetch https://example.com from the internet",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "External network request is ready"
    assert response.decision.selected_action == "external_network_request"
    assert response.decision.confirmation == :pending
    assert response.decision.permission == :external_network
    assert response.decision.user_id == "local"
    assert response.decision.thread_id == response.thread_id

    assert [%{operation_class: :external_service_request, access_mode: :fetch}] =
             response.resource_access

    assert [
             %{
               name: "external_network_request",
               execution: :pending_confirmation,
               confirmation_id: confirmation_id,
               approval_handoff: action_handoff
             }
           ] = response.actions

    assert response.approval_handoff.confirmation_id == confirmation_id
    assert response.approval_handoff.status == :pending
    assert response.approval_handoff == action_handoff

    assert get_in(response.approval_handoff, [:target_action, :action, "name"]) ==
             "external_network_request"

    assert :approve in response.approval_handoff.allowed_actions
    assert :deny in response.approval_handoff.allowed_actions
    assert :details in response.approval_handoff.allowed_actions
    assert %{remember: :exact_resource} in response.approval_handoff.allowed_actions

    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["origin"]["channel"] == "test"
    assert pending["origin"]["user_id"] == "local"
    assert pending["origin"]["thread_id"] == response.thread_id
    assert pending["target_execution_mode"] == "req_http"

    assert {:ok, %{messages: [_user_message, assistant_message]}} =
             Conversations.show_thread("local", response.thread_id)

    assert action_log_value(assistant_message.action_log, "status") in [
             :needs_confirmation,
             "needs_confirmation"
           ]

    assert action_log_value(assistant_message.action_log, "approval_handoff")
    assert action_log_value(assistant_message.action_log, "resource_access")
  end

  test "default runtime creates URL summarization confirmation before fetching" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Please check https://example.com/report and summarize it",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "External network request is ready"
    assert response.message =~ "Operation: summarize_url"
    assert response.decision.intent == :summarize_url
    assert response.decision.selected_action == "external_network_request"
    assert response.decision.confirmation == :pending

    selected_candidate = response.decision.trace_metadata.intent_candidates.selected
    assert selected_candidate.kind == :action
    assert selected_candidate.action_name == "external_network_request"
    assert [%{operation_class: :summarize_url}] = selected_candidate.resource_access

    assert [
             %{
               name: "external_network_request",
               execution: :pending_confirmation,
               confirmation_id: confirmation_id
             }
           ] = response.actions

    assert [%{operation_class: :summarize_url, access_mode: :summarize}] =
             response.resource_access

    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["params_summary"]["operation_class"] == "summarize_url"
    assert [ref] = pending["params_summary"]["resource_refs"]
    assert ref["operation_class"] == "summarize_url"
    assert ref["downstream_consumer"] == "url_summarizer"
  end

  test "default runtime persists denied URL summarization without crashing" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Please check https://wikipedia.com/report and summarize it",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :denied
    assert response.message =~ "External network request was denied"

    assert {:ok, %{messages: [_user_message, assistant_message]}} =
             Conversations.show_thread("local", response.thread_id)

    assert Jason.encode!(assistant_message.action_log)
    assert action_log_value(assistant_message.action_log, "status") == "denied"

    denial_reason =
      get_in(assistant_message.action_log, [
        "actions",
        Access.at(0),
        "request",
        "denial_reason"
      ])

    assert denial_reason =~ "host_not_allowlisted"
    assert denial_reason =~ "wikipedia.com"
  end

  test "default runtime trace includes confirmation metadata for external network requests", %{
    root: root
  } do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Fetch https://example.com from the internet",
               channel: :test,
               operator_id: "local",
               metadata: %{trace: true}
             })

    assert response.status == :needs_confirmation
    assert response.trace_id =~ Path.join(root, "traces")

    assert [
             %{
               name: "external_network_request",
               confirmation_id: confirmation_id
             }
           ] = response.actions

    trace = File.read!(response.trace_id)
    assert trace =~ "## Intent Decision"
    assert trace =~ "## Intent Candidates"
    assert trace =~ "Selected: action/external_network_request"
    assert trace =~ "Intent decision: external_network_request"
    assert trace =~ "resource_access_count: 1"
    assert trace =~ "approval_handoff"
    assert trace =~ "confirmation_id: #{inspect(confirmation_id)}"
    assert trace =~ "confirmation_metadata"
    assert trace =~ "## Confirmation Metadata"

    assert trace =~
             "#{confirmation_id} status=pending target=external_network_request origin=test"
  end

  test "default runtime trace includes bounded shell command metadata", %{root: root} do
    put_execution_policy!(File.cwd!())

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "run pwd",
               channel: :test,
               operator_id: "local",
               metadata: %{trace: true}
             })

    assert response.status == :needs_confirmation
    assert response.trace_id =~ Path.join(root, "traces")

    assert response.decision.trace_metadata.intent_candidates.selected.action_name ==
             "run_shell_command"

    trace = File.read!(response.trace_id)
    assert trace =~ "Selected action: run_shell_command"
    assert trace =~ "## Shell Command Metadata"
    assert trace =~ "Command: pwd"
    assert trace =~ "Sandbox: level 1"
    refute trace =~ "stdout:"
  end

  test "default runtime activates trusted skill instructions" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Activate skill append-memory",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :completed
    assert response.message =~ "## Skill Context"
    assert response.message =~ "append-memory"
    assert [%{name: "activate_skill", selected_skill: "append-memory"}] = response.actions
  end

  test "default runtime writes and reads markdown memory", %{root: root} do
    assert {:ok, write_response} =
             Runtime.submit_user_input(%{
               text: "Remember that my planning docs should be implementation-ready.",
               channel: :test,
               operator_id: "local"
             })

    assert write_response.status == :completed

    assert [%{name: "append_memory", durable: true, memory_path: memory_path}] =
             write_response.actions

    assert memory_path =~ root
    assert File.exists?(memory_path)

    assert {:ok, read_response} =
             Runtime.submit_user_input(%{
               text: "What do you remember about my planning docs?",
               channel: :test,
               operator_id: "local"
             })

    assert read_response.status == :completed
    assert read_response.message =~ "planning docs should be implementation-ready"
    assert [%{name: "read_recent_memory", memory_count: 1}] = read_response.actions
  end

  test "default runtime captures and recalls personal preference heuristics", %{root: root} do
    assert {:ok, name_response} =
             Runtime.submit_user_input(%{
               text: "my name is Sandeep",
               channel: :test,
               operator_id: "local"
             })

    assert name_response.status == :completed

    assert [%{name: "append_memory", memory_category: :preferences, memory_path: name_path}] =
             name_response.actions

    assert name_path =~ Path.join(root, "preferences")
    assert File.exists?(name_path)

    assert {:ok, recall_response} =
             Runtime.submit_user_input(%{
               text: "what is my name?",
               channel: :test,
               operator_id: "local"
             })

    assert recall_response.status == :completed
    assert recall_response.message =~ "Preferred name: Sandeep"
    assert [%{name: "read_recent_memory", memory_count: 1}] = recall_response.actions
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

  defp put_execution_policy!(workspace) do
    settings = %{
      "permissions" => %{"command_execute" => "allowed"},
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace]
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp action_log_value(action_log, key) do
    Map.get(action_log, key) || Map.get(action_log, String.to_atom(key))
  end
end
