defmodule Mix.Tasks.Stocksage.QueueTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stocksage.Queue, as: QueueTask
  alias AllbertAssist.Settings
  alias StockSage.Queue

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-queue-task-settings-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
      Mix.Task.reenable("stocksage.queue")
    end)

    :ok
  end

  test "creates and lists queue rows with default local user" do
    create_output =
      capture_io(fn ->
        assert :ok = QueueTask.run(["create", "tsla", "--thread-id", "thread_1"])
      end)

    assert create_output =~ "Symbol: TSLA"
    assert [%{id: queue_id}] = Queue.list_entries("local")

    Mix.Task.reenable("stocksage.queue")

    list_output =
      capture_io(fn ->
        assert :ok = QueueTask.run(["list", "--user", "local", "--status", "queued"])
      end)

    assert list_output =~ queue_id
    assert list_output =~ "TSLA"
  end

  test "user scoped queue list isolates rows" do
    assert {:ok, _entry} = Queue.create_entry(%{user_id: "alice", symbol: "aapl"})

    output =
      capture_io(fn ->
        assert :ok = QueueTask.run(["list", "--user", "bob"])
      end)

    assert output =~ "Returned: 0"
    refute output =~ "AAPL"
  end

  test "fails when user and operator differ" do
    assert_raise Mix.Error, ~r/--user alice differs from --operator bob/, fn ->
      capture_io(fn ->
        QueueTask.run(["list", "--user", "alice", "--operator", "bob"])
      end)
    end
  end

  test "create respects stocksage_write denial through the action runner" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "permissions" => %{"stocksage_write" => "denied"}
             })

    assert_raise Mix.Error, ~r/permission_denied/, fn ->
      capture_io(fn ->
        QueueTask.run(["create", "tsla", "--user", "alice"])
      end)
    end

    assert [] = Queue.list_entries("alice")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
