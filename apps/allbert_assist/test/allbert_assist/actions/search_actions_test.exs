defmodule AllbertAssist.Actions.SearchActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-search-action-#{System.unique_integer([:positive])}")

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

  test "registered Search action returns the central DTO through Runner" do
    assert {:ok, module} = Registry.resolve("search_conversations")
    assert module == AllbertAssist.Actions.Search.SearchConversations

    assert {:ok, thread} = Conversations.create_general_thread("alice", "Action")

    assert {:ok, message} =
             Conversations.append_user_message(thread, "registered central search",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, _build} = Projection.rebuild("alice")

    assert {:ok, response} =
             Runner.run(
               "search_conversations",
               %{query: "central search", limit: 10},
               %{operator_id: "alice", user_id: "alice", channel: "tui"}
             )

    assert response.status == :completed

    assert [%{source_id: source_id, snippet: "registered central search"}] =
             response.search_page.results

    assert source_id == message.id
    assert response.runner_metadata.action_name == "search_conversations"
  end

  test "search-result render marker is excluded from Corpus projection input" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Render exclusion")
    assert {:ok, _ordinary} = local_message(thread, "ordinary searchable source")

    assert {:ok, _rendered} =
             Conversations.append_assistant_message(thread, "ordinary searchable source",
               metadata: %{"channel" => "tui", "content_kind" => "search_result_render"}
             )

    assert {:ok, build} = Projection.rebuild("alice")
    assert build.document_count == 1
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
