defmodule AllbertAssist.RuntimeIntentAgentTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Runtime

  setup do
    original_config = Application.get_env(:allbert_assist, Runtime)
    Application.delete_env(:allbert_assist, Runtime)

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Runtime, original_config)
      else
        Application.delete_env(:allbert_assist, Runtime)
      end
    end)
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
end
