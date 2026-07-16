defmodule Mix.Tasks.Allbert.ConversationsTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias Mix.Tasks.Allbert.Conversations, as: ConversationsTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-conversations-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    PluginRegistry.clear()
    PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    PluginRegistry.register_module(AllbertAssist.Plugins.Discord)
    PluginRegistry.register_module(AllbertAssist.Plugins.Slack)

    on_exit(fn ->
      Mix.Task.reenable("allbert.conversations")
      ShippedRegistries.restore!()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "shows redacted unified history from canonical thread refs" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "CLI history")
    assert {:ok, message} = Conversations.append_user_message(thread, "token sk-cli123")

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               canonical_thread_id: thread.id,
               canonical_message_id: message.id,
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               provider_message_id: "user-1",
               direction: :in
             })

    output =
      capture_io(fn ->
        assert :ok = ConversationsTask.run(["show", thread.id, "--user", "alice"])
      end)

    assert output =~ "Thread: #{thread.id}"
    assert output =~ "Channels:"
    assert output =~ "slack receiver=slack:T0123"
    assert output =~ "token [REDACTED]"
    refute output =~ "sk-cli123"
  end

  test "resumes a local CLI surface without external identity link" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "CLI resume")

    output =
      capture_io(fn ->
        assert :ok =
                 ConversationsTask.run([
                   "resume",
                   thread.id,
                   "--channel",
                   "cli",
                   "--user",
                   "alice"
                 ])
      end)

    assert output =~ "Resumed thread #{thread.id}"
    assert output =~ "for alice on cli"
    assert output =~ "Continuity: rich_surface"
    refute output =~ "for local on cli"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
