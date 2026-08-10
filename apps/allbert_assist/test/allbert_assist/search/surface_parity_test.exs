defmodule AllbertAssist.Search.SurfaceParityTest do
  use AllbertAssist.DataCase, async: false
  alias AllbertAssist.Channels.TUI.SlashCommands
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Surface
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.TestSupport.ReadyEffectContext

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    original_settings = Application.get_env(:allbert_assist, Settings)
    parent = self()

    root =
      Path.join(System.tmp_dir!(), "allbert-search-surface-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:agent_runner_called, request.text})
        {:ok, %{message: "unexpected model call", status: :completed}}
      end
    )

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

  test "local Web, TUI, and CLI consume the same action DTO and source presentation" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Surface parity")

    assert {:ok, source} =
             Conversations.append_user_message(thread, "surface parity phrase",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, _build} = Projection.rebuild("alice")

    tui_context = local_context("tui")
    cli_context = local_context("cli")

    assert {:ok, tui} = SlashCommands.dispatch(~s(/search "surface parity"), tui_context)

    assert {:ok, cli} =
             Surface.dispatch_argv(
               [
                 "--limit",
                 "10",
                 "--order",
                 "newest",
                 "--author",
                 "operator",
                 "--",
                 ~s("surface parity")
               ],
               cli_context
             )

    assert {:ok, web} =
             Runtime.submit_user_input(%{
               text: ~s(/search "surface parity"),
               channel: :live_view,
               user_id: "alice",
               operator_id: "alice",
               thread_id: thread.id
             })

    for response <- [tui, cli, web] do
      assert response.status == :completed
      assert Enum.map(response.search_page.results, & &1.source_id) == [source.id]
      assert response.surface_payload =~ "[operator · tui ·"
      assert response.surface_payload =~ "source: conversation:#{source.id} thread:#{thread.id}"
    end

    refute_received {:agent_runner_called, _text}
    assert {:ok, rendered_message} = Conversations.get_message("alice", web.assistant_message_id)
    assert rendered_message.metadata["content_kind"] == "search_result_render"
  end

  test "mapped DM defaults to the exact current origin and discloses E2EE opt-in" do
    assert {:ok, _link} = ChannelThread.link_identity(identity_attrs())

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :search,
               :mapped_operator_dm,
               true,
               ReadyEffectContext.context()
             )

    assert {:ok, local_thread} = Conversations.create_general_thread("alice", "Local private")

    assert {:ok, local_source} =
             Conversations.append_user_message(local_thread, "bounded privacy phrase",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, seeded_dm} =
             Runtime.submit_user_input(%{
               text: "bounded privacy phrase",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref(:server_readable),
               provider_message_id: "surface-parity-seed"
             })

    assert_received {:agent_runner_called, "bounded privacy phrase"}
    assert {:ok, _build} = Projection.rebuild("alice")

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "/search bounded privacy",
               channel: "slack",
               user_id: "alice",
               external_user_id: "U_ALICE",
               channel_thread_ref: slack_ref(:server_readable),
               provider_message_id: "surface-parity-query"
             })

    ids = Enum.map(response.search_page.results, & &1.source_id)
    assert seeded_dm.user_message_id in ids
    refute local_source.id in ids
    refute_received {:agent_runner_called, "/search bounded privacy"}

    assert {:ok, e2ee} =
             Surface.dispatch_text("/search bounded privacy", %{
               operator_id: "alice",
               user_id: "alice",
               channel: "slack",
               thread_id: response.thread_id,
               source_message_id: seeded_dm.user_message_id,
               origin: exact_origin(),
               trust_class: :e2ee_origin,
               conversation_scope: :direct
             })

    assert e2ee.search_disclosure =~ "E2EE-origin text is excluded"
    assert e2ee.surface_payload =~ "local plaintext derivatives"

    assert {:ok, shared} =
             Surface.dispatch_text("/search bounded privacy", %{
               operator_id: "alice",
               user_id: "alice",
               channel: "slack",
               thread_id: response.thread_id,
               source_message_id: seeded_dm.user_message_id,
               origin: exact_origin(),
               trust_class: :server_readable,
               conversation_scope: :shared
             })

    assert shared.status == :denied
    assert shared.error == :search_scope_excluded
    assert shared.surface_payload =~ "one-to-one operator DMs only"
  end

  defp local_context(channel) do
    %{operator_id: "alice", user_id: "alice", channel: channel, surface: channel}
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

  defp slack_ref(trust_class) do
    %{
      owner_scope: "local",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: "1718040000.000900"
      },
      trust_class: trust_class,
      conversation_scope: :direct
    }
  end

  defp exact_origin do
    %{
      owner_scope: "local",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_key: "slack:T0123:C0123:1718040000.000900"
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
