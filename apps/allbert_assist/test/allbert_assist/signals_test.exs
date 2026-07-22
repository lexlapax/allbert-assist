defmodule AllbertAssist.SignalsTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  import ExUnit.CaptureLog

  alias AllbertAssist.Signals
  alias Jido.Signal.Bus

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

  test "objective and runtime turn signal helpers redact and publish through the signal bus" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.objective.**")

    original_logger_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn ->
          assert {:ok, signal} =
                   Signals.objective_lifecycle(:created, %{
                     objective_id: "obj_signal",
                     user_id: "alice",
                     title: "Analyze AAPL",
                     api_key: "sk-test"
                   })

          assert signal.type == "allbert.objective.created"
          assert signal.data.api_key == "[REDACTED]"
          :ok = Signals.log(signal)
        end)
      after
        Logger.configure(level: original_logger_level)
      end

    assert log =~ "allbert.objective.created"

    assert_receive {:signal, signal}, 1_000
    assert signal.type == "allbert.objective.created"
    assert signal.data.objective_id == "obj_signal"
    refute inspect(signal.data) =~ "sk-test"

    assert {:ok, started} = Signals.runtime_turn_started(%{user_id: "alice", trace_id: "trace_1"})

    assert {:ok, completed} =
             Signals.runtime_turn_completed(%{user_id: "alice", trace_id: "trace_1"})

    assert started.type == "allbert.runtime.turn.started"
    assert completed.type == "allbert.runtime.turn.completed"
    assert completed.data.trace_id == "trace_1"
  end

  test "fanout lifecycle signals are pushed through the bus and redacted" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.objectives.run.**")

    assert :ok =
             Signals.emit_fanout(:run_progress, %{
               parent_id: "parent-1",
               child_id: "child-1",
               operation: :execute,
               api_key: "sk-secret"
             })

    assert_receive {:signal, signal}, 1_000
    assert signal.type == "allbert.objectives.run.progress"
    assert signal.data.child_id == "child-1"
    assert signal.data.api_key == "[REDACTED]"
    refute inspect(signal.data) =~ "sk-secret"
  end

  test "objective signal payloads are bounded" do
    assert {:ok, signal} =
             Signals.objective_lifecycle(:observed, %{
               objective_id: "obj_bound",
               user_id: "alice",
               observation_summary: String.duplicate("x", 2_100)
             })

    assert byte_size(signal.data.observation_summary) <= 2_003
  end

  test "registration lifecycle helpers redact and publish through the signal bus" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.app.**")

    Signals.emit_registration(:app_registered, %{
      app_id: :signal_test_app,
      app_module: "SignalTestApp",
      api_key: "sk-registration-secret"
    })

    assert_receive {:signal, signal}, 1_000
    assert signal.type == "allbert.app.registered"
    assert signal.data.app_id == :signal_test_app
    assert signal.data.api_key == "[REDACTED]"
    refute inspect(signal.data) =~ "sk-registration-secret"
  end
end
