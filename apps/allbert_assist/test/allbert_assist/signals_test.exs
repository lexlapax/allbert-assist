defmodule AllbertAssist.SignalsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Signals

  test "redacts sensitive keys recursively" do
    assert Signals.redact(%{
             api_key: "sk-test",
             nested: %{
               "token" => "token-value",
               values: [%{password: "pw"}, %{safe: "visible"}]
             },
             safe: "visible"
           }) == %{
             api_key: "[REDACTED]",
             nested: %{
               "token" => "[REDACTED]",
               values: [%{password: "[REDACTED]"}, %{safe: "visible"}]
             },
             safe: "visible"
           }
  end

  test "action lifecycle signals redact params and response summaries" do
    skill_metadata = %{
      selected_skill: "append-memory",
      capability_contract: %{validation_status: :valid, api_key: "sk-skill"}
    }

    action_capability = %{name: "append_memory", permission: :memory_write}

    {:ok, requested} =
      Signals.action_requested(
        "set_provider_credential",
        AllbertAssist.Actions.Settings.SetProviderCredential,
        %{provider: "openai", api_key: "sk-test"},
        %{
          request: %{operator_id: "local", channel: :test, input_signal_id: "sig"},
          selected_skill: "append-memory",
          skill_metadata: skill_metadata,
          action_capability: action_capability
        }
      )

    assert requested.data.params.api_key == "[REDACTED]"
    assert requested.data.selected_skill == "append-memory"
    assert requested.data.contract_status == :valid
    assert requested.data.skill_metadata.capability_contract.api_key == "[REDACTED]"
    assert requested.data.action_capability.name == "append_memory"
    refute inspect(requested.data) =~ "sk-test"
    refute inspect(requested.data) =~ "sk-skill"

    {:ok, completed} =
      Signals.action_completed(
        "set_provider_credential",
        AllbertAssist.Actions.Settings.SetProviderCredential,
        :completed,
        %{
          status: :completed,
          message: "saved",
          credential: "sk-test",
          actions: [
            %{
              name: "set_provider_credential",
              credential: "sk-test",
              credential_status: :configured
            }
          ]
        },
        %{
          request: %{operator_id: "local", channel: :test},
          selected_skill: "append-memory",
          skill_metadata: skill_metadata,
          action_capability: action_capability
        },
        12
      )

    assert completed.data.selected_skill == "append-memory"
    assert completed.data.contract_status == :valid
    assert completed.data.skill_metadata.capability_contract.api_key == "[REDACTED]"
    assert [%{credential: "[REDACTED]"}] = completed.data.response.actions
    refute inspect(completed.data) =~ "sk-test"
    refute inspect(completed.data) =~ "sk-skill"
  end
end
