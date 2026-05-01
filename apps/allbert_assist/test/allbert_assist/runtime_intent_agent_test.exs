defmodule AllbertAssist.RuntimeIntentAgentTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Memory
  alias AllbertAssist.Runtime

  setup do
    original_config = Application.get_env(:allbert_assist, Runtime)
    original_memory_config = Application.get_env(:allbert_assist, Memory)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-runtime-memory-test-#{System.unique_integer([:positive])}"
      )

    Application.delete_env(:allbert_assist, Runtime)
    Application.put_env(:allbert_assist, Memory, root: root)

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
    assert response.message =~ "I will not execute shell commands"
    assert [%{name: "plan_shell_command", execution: :not_available}] = response.actions
  end

  test "default runtime requires confirmation for external network requests" do
    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Fetch https://example.com from the internet",
               channel: :test,
               operator_id: "local"
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "external network access"
    assert [%{name: "external_network_request", execution: :not_available}] = response.actions
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
end
