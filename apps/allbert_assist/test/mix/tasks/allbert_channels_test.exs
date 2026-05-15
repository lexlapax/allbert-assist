defmodule Mix.Tasks.Allbert.ChannelsTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias Mix.Tasks.Allbert.Channels, as: ChannelsTask

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-channels-task-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Task channel response: #{request.text}", status: :completed}}
      end
    )

    on_exit(fn ->
      restore_env(Memory, original_memory_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      Mix.Task.reenable("allbert.channels")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "lists and shows channel summaries through registered actions" do
    list_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["list"])
      end)

    assert list_output =~ "telegram provider=telegram_bot_api"
    assert list_output =~ "email provider=email_imap"
    refute list_output =~ "token"

    Mix.Task.reenable("allbert.channels")

    show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "telegram"])
      end)

    assert show_output =~ "Channel: telegram"
    assert show_output =~ "Provider: telegram_bot_api"

    Mix.Task.reenable("allbert.channels")

    email_show_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["show", "email"])
      end)

    assert email_show_output =~ "Channel: email"
    assert email_show_output =~ "Provider: email_imap"
  end

  test "stores credentials without printing secret values" do
    telegram_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["telegram", "set-token", "tg-secret"])
      end)

    assert telegram_output =~ "telegram bot_token=stored"
    refute telegram_output =~ "tg-secret"
    assert Secrets.status("secret://channels/telegram/bot_token") == :configured

    Mix.Task.reenable("allbert.channels")

    email_output =
      capture_io(fn ->
        assert :ok = ChannelsTask.run(["email", "set-password", "--type", "imap", "imap-secret"])
      end)

    assert email_output =~ "email imap_password=stored"
    refute email_output =~ "imap-secret"
    assert Secrets.status("secret://channels/email/imap_password") == :configured
  end

  test "maps identities and simulates both channels without provider access" do
    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "telegram",
                 "map",
                 "--external-user",
                 "123",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    telegram_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "telegram",
                   "simulate",
                   "--external-user",
                   "123",
                   "--chat",
                   "456",
                   "/new hello"
                 ])
      end)

    assert telegram_output =~ "status=processed"
    assert telegram_output =~ "User: alice"
    assert telegram_output =~ "Task channel response: hello"
    assert_received {:runtime_request, %{channel: "telegram", text: "hello"}}

    Mix.Task.reenable("allbert.channels")

    capture_io(fn ->
      assert :ok =
               ChannelsTask.run([
                 "email",
                 "map",
                 "--external-user",
                 "alice@example.com",
                 "--user",
                 "alice"
               ])
    end)

    Mix.Task.reenable("allbert.channels")

    seed_email_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "email",
                   "simulate",
                   "--external-user",
                   "alice@example.com",
                   "email seed"
                 ])
      end)

    assert seed_email_output =~ "status=processed"
    assert seed_email_output =~ "Task channel response: email seed"
    assert_received {:runtime_request, %{channel: "email", text: "email seed"}}

    Mix.Task.reenable("allbert.channels")

    new_thread_email_output =
      capture_io(fn ->
        assert :ok =
                 ChannelsTask.run([
                   "email",
                   "simulate",
                   "--external-user",
                   "alice@example.com",
                   "--new-thread",
                   "email hello"
                 ])
      end)

    assert new_thread_email_output =~ "status=processed"
    assert new_thread_email_output =~ "Task channel response: email hello"
    assert_received {:runtime_request, %{channel: "email", text: "email hello"}}

    email_threads =
      Event
      |> where([event], event.channel == "email")
      |> order_by([event], asc: event.inserted_at)
      |> select([event], event.thread_id)
      |> Repo.all()

    assert length(Enum.uniq(email_threads)) == 2
    assert Repo.aggregate(Event, :count) == 3
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
