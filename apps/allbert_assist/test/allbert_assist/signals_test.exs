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
    {:ok, requested} =
      Signals.action_requested(
        "set_provider_credential",
        AllbertAssist.Actions.Settings.SetProviderCredential,
        %{provider: "openai", api_key: "sk-test"},
        %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}}
      )

    assert requested.data.params.api_key == "[REDACTED]"
    refute inspect(requested.data) =~ "sk-test"

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
        %{request: %{operator_id: "local", channel: :test}},
        12
      )

    assert [%{credential: "[REDACTED]"}] = completed.data.response.actions
    refute inspect(completed.data) =~ "sk-test"
  end
end
