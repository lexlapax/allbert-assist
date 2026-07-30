defmodule AllbertAssist.Actions.RunnerSearchSummaryTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias Jido.Signal.Bus

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-search-summary-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    KeyCustody.invalidate(:all)
    start_supervised!({Projection, root: Path.join(root, "projection"), name: Projection})

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "Runner applies Search summary before requested and completed signals" do
    assert {:ok, _subscription} = Bus.subscribe(AllbertAssist.SignalBus, "allbert.action.**")
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Signals")

    assert {:ok, _message} =
             Conversations.append_user_message(thread, "signal private query fixture",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, _build} = Projection.rebuild("alice")

    query = "signal private query"
    private_thread = "thread-private-filter"

    assert {:ok, response} =
             Runner.run(
               "search_conversations",
               %{query: query, filters: %{thread_ids: [thread.id]}, limit: 5},
               %{operator_id: "alice", user_id: "alice", channel: "tui"}
             )

    assert response.status == :completed
    assert_receive {:signal, requested}, 1_000
    assert_receive {:signal, completed}, 1_000
    assert requested.type == "allbert.action.requested"
    assert completed.type == "allbert.action.completed"

    serialized = inspect([requested.data, completed.data])
    refute serialized =~ query
    refute serialized =~ private_thread
    refute serialized =~ thread.id
    refute serialized =~ "signal private query fixture"
    assert requested.data.params.filter_kinds == [:thread_ids]
    assert completed.data.response.result_count == 1
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
