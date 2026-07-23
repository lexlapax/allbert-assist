defmodule AllbertAssist.Channels.TUISubscriptionsTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Channels.TUI.Subscriptions
  alias AllbertAssist.Objectives
  alias Jido.Signal

  test "renders only signals owned by the attached identity map" do
    assert {:ok, alice} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Owned fan-out",
               objective: "owned",
               fanout_role: "parent"
             })

    assert {:ok, mallory} =
             Objectives.create_objective(%{
               user_id: "mallory",
               title: "Foreign fan-out",
               objective: "foreign",
               fanout_role: "parent"
             })

    identity_map = [%{"external_user_id" => "local", "user_id" => "alice", "enabled" => true}]

    owned =
      Signal.new!("allbert.objectives.fanout.joined", %{parent_id: alice.id, title: alice.title})

    foreign = Signal.new!("allbert.objectives.fanout.joined", %{parent_id: mallory.id})

    assert Subscriptions.attached_user_signal?(owned, identity_map)
    refute Subscriptions.attached_user_signal?(foreign, identity_map)
    assert Subscriptions.status_line(owned) == "[fan-out] fanout joined: Owned fan-out"
  end

  test "disabled sessions do not register" do
    assert {:ok, nil} = Subscriptions.register(false)
    assert :ok = Subscriptions.unregister(nil)
  end
end
