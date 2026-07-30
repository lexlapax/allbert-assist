defmodule AllbertAssist.Search.QueryScopeTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Search
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-search-scope-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Runtime, agent_runner: &runtime_response/2)
    KeyCustody.invalidate(:all)
    start_supervised!({Projection, root: Path.join(root, "projection"), name: Projection})

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      restore_env(Paths, original_paths)
      restore_env(Runtime, original_runtime)
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "mapped DM cross-surface approval stores no query and requires exact resubmission" do
    assert {:ok, _link} = ChannelThread.link_identity(identity_attrs("U_ALICE"))
    assert {:ok, _epoch} = Corpus.set_origin_grant(:search, :mapped_operator_dm, true)

    assert {:ok, turn} =
             Runtime.submit_user_input(%{
               text: "remote private searchable phrase",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref("1718040000.000900"),
               provider_message_id: "remote-search-scope-1"
             })

    assert {:ok, [{:ok, envelope}]} =
             Corpus.rehydrate_and_authorize("alice", [turn.user_message_id], mapped_policy())

    assert {:ok, _build} = Projection.rebuild("alice")

    base_context = %{
      operator_id: "alice",
      user_id: "alice",
      channel: "slack",
      origin_scope: :mapped_operator_dm,
      thread_id: envelope.thread_id,
      origin: envelope.origin,
      source_message_id: envelope.source_id,
      search_scope: :cross_surface
    }

    request = %{query: "remote private", order: :relevance, limit: 10}
    assert {:error, :query_confirmation_required} = Search.query(request, base_context)

    authorize_params =
      request
      |> Map.merge(%{
        source_message_id: envelope.source_id,
        operator_id: "alice",
        thread_id: envelope.thread_id,
        origin: envelope.origin
      })

    assert {:ok, authorization} =
             Runner.run("authorize_search_query_scope", authorize_params, base_context)

    assert authorization.status == :needs_confirmation
    confirmation_id = authorization.confirmation_id
    assert {:ok, pending} = Confirmations.read(confirmation_id)
    serialized = inspect(pending)
    refute serialized =~ "remote private"
    refute serialized =~ ~s("query")
    assert pending["resume_params_ref"]["requested_scope"] == "cross_surface"
    assert pending["resume_params_ref"]["filter_count"] == 0
    assert (pending["resume_params_ref"]["expires_at"] - System.system_time(:second)) in 299..300

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: confirmation_id},
               %{operator_id: "alice", user_id: "alice", channel: "tui"}
             )

    assert approval.status == :completed
    assert {:ok, %{"status" => "approved"} = approved} = Confirmations.read(confirmation_id)

    assert get_in(approved, ["operator_resolution", "target_result", "output_data", "outcome"]) in [
             "query_resubmit_required",
             :query_resubmit_required
           ]

    resubmitted = Map.put(request, :query_chain_id, confirmation_id)
    assert {:ok, page} = Search.query(resubmitted, base_context)
    assert Enum.any?(page.results, &(&1.source_id == envelope.source_id))

    assert {:error, :scope_denied} =
             Search.query(%{resubmitted | query: "changed request"}, base_context)
  end

  defp runtime_response(_signal, request) do
    {:ok, %{message: "Runtime response: #{request.text}", status: :completed, actions: []}}
  end

  defp identity_attrs(external_user_id) do
    %{
      owner_scope: "local",
      link_id: "operator-alice",
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      external_user_id: external_user_id
    }
  end

  defp slack_ref(thread_ts) do
    %{
      owner_scope: "local",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: thread_ts
      },
      trust_class: :server_readable
    }
  end

  defp mapped_policy do
    %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: false}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
