defmodule AllbertAssist.Actions.Channels.ChannelConfigActionsTest do
  @moduledoc """
  v0.62 M8.15 — the channel config/secret/identity writes moved onto the one
  action spine. These exercise the new gated actions directly: an allowed write
  succeeds and stays secret-free, and a denied gate never touches the store.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.ConfigureChannelSecret
  alias AllbertAssist.Actions.Channels.LinkChannelIdentity
  alias AllbertAssist.Actions.Channels.UnlinkChannelIdentity
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-channel-config-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      case original_settings_config do
        nil -> Application.delete_env(:allbert_assist, Settings)
        config -> Application.put_env(:allbert_assist, Settings, config)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  defp allowed_context, do: %{request: %{operator_id: "local", channel: :test}}

  # A context that claims an unregistered action boundary forces a Security
  # Central context denial regardless of the permission's configured floor. The
  # bogus name is never registered, so this denial is stable even after the real
  # channel actions are added to the registry.
  defp denied_context do
    %{
      request: %{operator_id: "local", channel: :test},
      selected_action: "unregistered_test_boundary"
    }
  end

  describe "configure_channel_secret" do
    test "stores the secret and its settings reference without leaking the value" do
      assert {:ok, response} =
               ConfigureChannelSecret.run(
                 %{channel: "telegram", credential: "bot_token", secret_value: "tg-secret"},
                 allowed_context()
               )

      assert response.status == :completed
      assert response.secret.channel == "telegram"
      assert response.secret.credential == "bot_token"
      assert response.secret.secret_ref == "secret://channels/telegram/bot_token"
      refute inspect(response) =~ "tg-secret"

      assert Secrets.status("secret://channels/telegram/bot_token") == :configured

      # The ref key is schema-sensitive, so Settings.get redacts it on read — a
      # configured (non-empty) value proves the reference was written; the raw
      # ref is reported on the action response above.
      assert {:ok, stored_ref} = Settings.get("channels.telegram.bot_token_ref")
      assert stored_ref not in [nil, ""]
    end

    test "rejects an unknown channel credential without writing" do
      assert {:ok, response} =
               ConfigureChannelSecret.run(
                 %{
                   channel: "telegram",
                   credential: "not_a_credential",
                   secret_value: "tg-secret"
                 },
                 allowed_context()
               )

      assert response.status == :denied
      refute inspect(response) =~ "tg-secret"
    end

    test "a denied gate never stores the secret" do
      assert {:ok, response} =
               ConfigureChannelSecret.run(
                 %{channel: "telegram", credential: "bot_token", secret_value: "tg-secret"},
                 denied_context()
               )

      assert response.status == :denied
      refute inspect(response) =~ "tg-secret"
      assert Secrets.status("secret://channels/telegram/bot_token") == :missing
    end
  end

  describe "link_channel_identity / unlink_channel_identity" do
    @attrs %{
      link_id: "link_alice",
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:team:T0123ABCDE",
      external_user_id: "U0123ABCDE"
    }

    test "links then unlinks an explicit cross-channel identity" do
      assert {:ok, linked} = LinkChannelIdentity.run(@attrs, allowed_context())
      assert linked.status == :completed
      assert linked.link.link_id == "link_alice"
      assert linked.link.channel == "slack"

      assert [%{link_id: "link_alice", channel: "slack"}] =
               ChannelThread.list_identity_links(%{link_id: "link_alice"})

      unlink_attrs = Map.delete(@attrs, :user_id)
      assert {:ok, unlinked} = UnlinkChannelIdentity.run(unlink_attrs, allowed_context())
      assert unlinked.status == :completed
      assert unlinked.link.link_id == "link_alice"

      assert ChannelThread.list_identity_links(%{link_id: "link_alice"}) == []
    end

    test "a denied gate never creates the identity link" do
      assert {:ok, response} =
               LinkChannelIdentity.run(@attrs, denied_context())

      assert response.status == :denied
      assert ChannelThread.list_identity_links(%{link_id: "link_alice"}) == []
    end
  end
end
