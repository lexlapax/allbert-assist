defmodule AllbertAssist.RuntimeIntentAgentTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations
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
    assert response.message =~ "v0.01-safe capabilities"
    assert [%{name: "list_skills"}] = response.actions
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

    assert [
             %{
               name: "external_network_request",
               execution: :pending_confirmation,
               confirmation_id: confirmation_id
             }
           ] = response.actions

    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["origin"]["channel"] == "test"
    assert pending["target_execution_mode"] == "req_http"
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
end
