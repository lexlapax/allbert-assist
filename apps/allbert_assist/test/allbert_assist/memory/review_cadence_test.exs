defmodule AllbertAssist.Memory.ReviewCadenceTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Jobs
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-review-cadence-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "daily cadence creates one active memory index rebuild job" do
    assert {:ok, setting} =
             Settings.put("memory.review_cadence", "daily", %{actor: "local", audit?: false})

    assert %{source: :memory_review_cadence, action: :created, cadence: "daily"} =
             Enum.find(setting.diagnostics, &(&1.source == :memory_review_cadence))

    assert [job] = Jobs.list_jobs("local")
    assert job.name == "memory-index-rebuild"
    assert job.status == "active"
    assert job.schedule == %{"kind" => "daily", "at" => "03:00"}
    assert job.target == %{"action_name" => "compile_memory_index", "params" => %{}}
    assert job.metadata["managed_by"] == "memory.review_cadence"
  end

  test "weekly cadence updates the managed job instead of duplicating it" do
    assert {:ok, _setting} =
             Settings.put("memory.review_cadence", "daily", %{actor: "local", audit?: false})

    assert {:ok, setting} =
             Settings.put("memory.review_cadence", "weekly", %{actor: "local", audit?: false})

    assert %{source: :memory_review_cadence, action: :updated, cadence: "weekly"} =
             Enum.find(setting.diagnostics, &(&1.source == :memory_review_cadence))

    assert [job] = Jobs.list_jobs("local")
    assert job.status == "active"
    assert job.schedule == %{"kind" => "weekly", "weekday" => "sunday", "at" => "03:00"}
    assert job.metadata["cadence"] == "weekly"
  end

  test "manual cadence pauses the managed job" do
    assert {:ok, _setting} =
             Settings.put("memory.review_cadence", "daily", %{actor: "local", audit?: false})

    assert {:ok, setting} =
             Settings.put("memory.review_cadence", "manual", %{actor: "local", audit?: false})

    assert %{source: :memory_review_cadence, action: :paused, cadence: "manual"} =
             Enum.find(setting.diagnostics, &(&1.source == :memory_review_cadence))

    assert [job] = Jobs.list_jobs("local")
    assert job.status == "paused"
    assert job.next_due_at == nil
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
