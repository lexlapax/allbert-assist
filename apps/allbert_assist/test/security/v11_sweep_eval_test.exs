defmodule AllbertAssist.Security.V11SweepEvalTest do
  @moduledoc "Gate-bound v1.1 fan-out authority and denial contracts."

  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels.ChannelParity
  alias AllbertAssist.Channels.NotifyConsentCallback
  alias AllbertAssist.Intent.Steering
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings.Schema

  @ids ~w[
    v11-fanout-model-001
    v11-scheduler-bounds-001
    v11-app-boundary-001
    v11-cancel-tiers-001
    v11-channel-parity-001
    v11-notify-default-off-001
    v11-notify-origin-deny-001
    v11-status-edit-001
    v11-steer-ownership-001
    v11-free-text-no-approve-001
    v11-surface-dispatch-001
  ]

  test "v1.1 inventory is complete, shaped, and routed" do
    rows = EvalInventory.rows_for_milestone(:v11)
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new(@ids)
    assert length(rows) == 11
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
    assert Enum.all?(rows, &(length(&1.assert) >= 3))
  end

  test "v11-fanout-model-001" do
    fields = Objective.__schema__(:fields)
    assert :fanout_role in fields and :parent_objective_id in fields
    assert "fanout_proposed" in Event.kinds()
    bind("v11-fanout-model-001")
  end

  test "v11-scheduler-bounds-001" do
    assert function_exported?(AllbertAssist.Objectives.Runs.Scheduler, :start_link, 1)
    assert function_exported?(AllbertAssist.Objectives.Runs.CancelToken, :checkpoint, 1)
    bind("v11-scheduler-bounds-001")
  end

  test "v11-app-boundary-001" do
    source = File.read!(Path.expand("../../lib/allbert_assist/actions/runner.ex", __DIR__))
    assert source =~ "AppRegistry"
    assert source =~ "active_app"
    bind("v11-app-boundary-001")
  end

  test "v11-cancel-tiers-001" do
    assert "cancel_objective_run" in Registry.names()
    assert function_exported?(AllbertAssist.Objectives.Runs.Cancel, :cancel, 2)
    bind("v11-cancel-tiers-001")
  end

  test "v11-channel-parity-001" do
    assert function_exported?(ChannelParity, :table, 1)
    assert function_exported?(ChannelParity, :verify, 1)
    bind("v11-channel-parity-001")
  end

  test "v11-notify-default-off-001" do
    for channel <- ~w[telegram email discord slack matrix whatsapp signal] do
      refute Schema.get_dotted(Schema.defaults(), "channels.#{channel}.autonomous_notify.enabled")
    end

    bind("v11-notify-default-off-001")
  end

  test "v11-notify-origin-deny-001" do
    source = File.read!(Path.expand("../../lib/allbert_assist/channels/notify.ex", __DIR__))
    assert source =~ "origin"
    assert source =~ "identity"
    bind("v11-notify-origin-deny-001")
  end

  test "v11-status-edit-001" do
    assert function_exported?(AllbertAssist.Channels.Outbound, :edit, 5)
    assert function_exported?(ChannelParity, :table, 1)
    bind("v11-status-edit-001")
  end

  test "v11-steer-ownership-001" do
    assert "steer_objective_run" in Registry.names()
    assert function_exported?(Objectives, :get_objective, 2)
    bind("v11-steer-ownership-001")
  end

  test "v11-free-text-no-approve-001" do
    assert :not_steering = Steering.classify("yes go ahead", [])
    refute NotifyConsentCallback.typed_command?("yes go ahead")
    bind("v11-free-text-no-approve-001")
  end

  test "v11-surface-dispatch-001" do
    source =
      File.read!(
        Path.expand(
          "../../../allbert_assist_web/lib/allbert_assist_web/live/objective_live.ex",
          __DIR__
        )
      )

    assert source =~ ~s(Runner.run("steer_objective_run")
    assert source =~ ~s(Runner.run("cancel_objective_run")
    bind("v11-surface-dispatch-001")
  end

  defp bind(id) do
    AssertBinding.check!(id, [:contract_present, :deny_path_bound, :runner_or_durable_boundary])
  end
end
