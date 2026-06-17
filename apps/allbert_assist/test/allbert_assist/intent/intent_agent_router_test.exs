defmodule AllbertAssist.Agents.IntentAgentRouterTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Intent.Router.FakeRouter
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.PendingStore

  setup do
    original = %{
      router: Application.get_env(:allbert_assist, :intent_router),
      outcome: Application.get_env(:allbert_assist, :intent_router_fake_outcome),
      override: Application.get_env(:allbert_assist, :intent_router_strategy_override)
    }

    Application.put_env(:allbert_assist, :intent_router, FakeRouter)
    Application.put_env(:allbert_assist, :intent_router_strategy_override, :two_stage_local)

    on_exit(fn ->
      restore(:intent_router, original.router)
      restore(:intent_router_fake_outcome, original.outcome)
      restore(:intent_router_strategy_override, original.override)
    end)

    %{
      uid: "u-#{System.unique_integer([:positive])}",
      tid: "t-#{System.unique_integer([:positive])}"
    }
  end

  test "a :clarify outcome renders a channel-answerable question and persists a pending clarification",
       %{uid: uid, tid: tid} do
    shortlist = [
      %{action_name: "create_note", app_id: :notes, label: "Create note"},
      %{action_name: "search_notes", app_id: :notes, label: "Search notes"}
    ]

    Application.put_env(
      :allbert_assist,
      :intent_router_fake_outcome,
      Outcome.clarify(shortlist, "Create or search notes?")
    )

    assert {:ok, response} = IntentAgent.respond(%{text: "note", user_id: uid, thread_id: tid})
    assert response.status == :needs_clarification
    assert response.message == "Create or search notes?"
    assert length(response.intent_clarification.options) == 2
    # no dead-end: there is a persisted, answerable clarification
    assert {:ok, pending} = PendingStore.take(uid, tid)
    assert Enum.map(pending.options, & &1.id) == ["create_note", "search_notes"]
  end

  test "a malformed :clarify shortlist is normalized before rendering", %{uid: uid, tid: tid} do
    shortlist = [%{action_name: "write_note", label: "Write note"} | :tail]

    Application.put_env(
      :allbert_assist,
      :intent_router_fake_outcome,
      Outcome.clarify(shortlist, "Which notes action?")
    )

    assert {:ok, response} =
             IntentAgent.respond(%{text: "note", user_id: uid, thread_id: tid})

    assert response.status == :needs_clarification
    assert [%{id: "write_note"}] = response.intent_clarification.options
    assert {:ok, pending} = PendingStore.take(uid, tid)
    assert [%{id: "write_note"}] = pending.options
  end

  test "a :none outcome declines gracefully (not a dead-end)", %{uid: uid, tid: tid} do
    Application.put_env(:allbert_assist, :intent_router_fake_outcome, Outcome.none())

    assert {:ok, response} =
             IntentAgent.respond(%{text: "fdsafdsa", user_id: uid, thread_id: tid})

    assert response.status == :completed
    assert response.message =~ "couldn't match"
    assert PendingStore.take(uid, tid) == :none
  end

  test "an :execute outcome for an app-scoped action runs in its app (reaches confirmation, not denied)",
       %{uid: uid, tid: tid} do
    # write_note is scoped to :notes_files; from a neutral active app the runner
    # used to deny it (:app_scope_denied). The router execute now sets the active
    # app to the action's app, so it reaches the confirmation gate instead.
    Application.put_env(
      :allbert_assist,
      :intent_router_fake_outcome,
      Outcome.execute("write_note", %{title: "v054", body: "hello"}, 1.0)
    )

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "create a note titled v054 with body hello",
               user_id: uid,
               thread_id: tid
             })

    refute response.status == :denied
    assert response.status == :needs_confirmation
  end

  test "an :execute outcome missing required action params clarifies instead of running the action",
       %{uid: uid, tid: tid} do
    Application.put_env(
      :allbert_assist,
      :intent_router_fake_outcome,
      Outcome.execute("write_note", %{}, 1.0)
    )

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "create a note about quarterly goals",
               user_id: uid,
               thread_id: tid
             })

    assert response.status == :needs_clarification
    assert response.message =~ "title and body"
    assert [%{name: "clarify_intent", status: :awaiting_clarification}] = response.actions

    assert [%{id: "write_note", missing_params: ["title", "body"]}] =
             response.intent_clarification.options

    assert {:ok, pending} = PendingStore.take(uid, tid)
    assert [%{id: "write_note", missing_params: ["title", "body"]}] = pending.options
  end

  defp restore(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
