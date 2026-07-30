defmodule AllbertAssist.Security.V13SearchEvalTest do
  @moduledoc "M8 behavioral proofs for Search surface and mapped-DM authority."

  use AllbertAssist.DataCase, async: false

  @moduletag :security_eval_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Surface
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.SecurityFixtures.EvalInventory

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v13-search-eval-#{System.unique_integer([:positive])}"
      )

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

  test "mapped-DM elevation is exact, allowlisted, content-free, and paginates without reprompt" do
    assert {:ok, _link} = ChannelThread.link_identity(identity_attrs())
    assert {:ok, _epoch} = Corpus.set_origin_grant(:search, :mapped_operator_dm, true)

    for title <- ["Local one", "Local two"] do
      assert {:ok, thread} = Conversations.create_general_thread("alice", title)

      assert {:ok, _source} =
               Conversations.append_user_message(thread, "surface chain local #{title}",
                 metadata: %{"channel" => "tui"}
               )
    end

    assert {:ok, dm_turn} =
             Runtime.submit_user_input(%{
               text: "surface chain remote origin",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref(),
               provider_message_id: "v13-search-eval-seed"
             })

    assert {:ok, [{:ok, envelope}]} =
             Corpus.rehydrate_and_authorize("alice", [dm_turn.user_message_id], mapped_policy())

    assert {:ok, _build} = Projection.rebuild("alice")
    context = mapped_context(envelope)

    command = ~s(/search --all-history --limit 1 --order newest -- "surface chain")
    assert {:ok, pending} = Surface.dispatch_text(command, context)
    assert pending.status == :needs_confirmation
    assert pending.approval_handoff.confirmation_id == pending.confirmation_id

    confirmation_id = pending.confirmation_id
    assert {:ok, stored} = Confirmations.read(confirmation_id)
    refute inspect(stored) =~ "surface chain"
    refute Map.has_key?(stored["resume_params_ref"], "query")
    assert stored["resume_params_ref"]["requested_scope"] == "cross_surface"

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: confirmation_id},
               %{operator_id: "alice", user_id: "alice", channel: "tui"}
             )

    assert approval.status == :completed
    refute approval.confirmation["status"] == "adapter_unavailable"

    resubmit =
      ~s(/search --all-history --limit 1 --order newest --chain #{confirmation_id} -- "surface chain")

    assert {:ok, page_one} = Surface.dispatch_text(resubmit, context)
    assert page_one.status == :completed
    assert is_nil(page_one.approval_handoff)
    assert is_binary(page_one.search_page.next_cursor)

    cursor = page_one.search_page.next_cursor

    paginate =
      ~s(/search --all-history --limit 1 --order newest --chain #{confirmation_id} --cursor #{cursor} -- "surface chain")

    assert {:ok, page_two} = Surface.dispatch_text(paginate, context)
    assert page_two.status == :completed
    assert is_nil(page_two.approval_handoff)
    refute page_two.search_page.results == page_one.search_page.results

    changed =
      ~s(/search --all-history --limit 1 --order newest --chain #{confirmation_id} -- changed request)

    assert {:ok, denied} = Surface.dispatch_text(changed, context)
    assert denied.status == :error
    assert denied.error == :scope_denied

    assert {:ok, approved_record} = Confirmations.read(confirmation_id)
    refute inspect(approved_record) =~ "surface chain"
  end

  test "surface consumers import only the registered command and DTO boundary" do
    surface = read_lib("allbert_assist/search/surface.ex")
    presentation = read_lib("allbert_assist/search/presentation.ex")
    cli = read_lib("allbert_assist/cli/areas/search.ex")

    for source <- [surface, presentation, cli] do
      refute source =~ "Search.SQLite"
      refute source =~ "Search.Projection"
      refute source =~ "Ecto.Query"
    end

    assert surface =~ ~s(Runner.run("search_conversations")
    assert surface =~ ~s(Runner.run("authorize_search_query_scope")
    assert cli =~ "AllbertAssist.Search.Surface"
  end

  test "the v1.3 behavioral inventory matches the request-flow contract without loss" do
    rows = EvalInventory.rows_for_milestone(:v13)
    ids = Enum.map(rows, & &1.id)

    assert length(ids) == length(Enum.uniq(ids))
    assert MapSet.new(ids) == documented_v13_ids()

    for row <- rows do
      assert row.assert != []
      assert is_binary(row.test_module) and row.test_module != ""
    end
  end

  defp mapped_context(envelope) do
    %{
      operator_id: "alice",
      user_id: "alice",
      channel: "slack",
      thread_id: envelope.thread_id,
      source_message_id: envelope.source_id,
      origin: envelope.origin,
      trust_class: :server_readable,
      conversation_scope: :direct
    }
  end

  defp identity_attrs do
    %{
      owner_scope: "local",
      link_id: "operator-alice",
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      external_user_id: "U_ALICE"
    }
  end

  defp slack_ref do
    %{
      owner_scope: "local",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: "1718040000.000900"
      },
      trust_class: :server_readable,
      conversation_scope: :direct
    }
  end

  defp mapped_policy,
    do: %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: false}

  defp runtime_response(_signal, request) do
    {:ok, %{message: "Runtime response: #{request.text}", status: :completed, actions: []}}
  end

  defp read_lib(relative) do
    __DIR__
    |> Path.join("../../lib")
    |> Path.join(relative)
    |> File.read!()
  end

  defp documented_v13_ids do
    request_flow =
      __DIR__
      |> Path.join("../../../../docs/plans/v1.3-request-flow.md")
      |> File.read!()

    [_, section] = String.split(request_flow, "### v1.3 rows", parts: 2)
    [table | _rest] = String.split(section, "Quality gates", parts: 2)

    table
    |> then(&Regex.scan(~r/`(v13-[^`]+-001)`/, &1, capture: :all_but_first))
    |> Enum.map(fn [id] -> id end)
    |> MapSet.new()
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
