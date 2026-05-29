defmodule StockSage.ProgressTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.{Paths, Plugin, Settings}
  alias StockSage.Progress

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "stocksage-progress-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    _ = Plugin.Registry.register_module(StockSage.Plugin)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "topic is scoped by user and analysis id with bounded safe segments" do
    assert Progress.topic("local user", "ana/with spaces") ==
             "stocksage_progress:local-user:ana-with-spaces"
  end

  test "normalizes bounded redacted progress payloads" do
    payload =
      Progress.normalize_payload(%{
        analysis_id: "ana_test",
        objective_id: "obj_test",
        stage: "unknown-stage",
        status: "running",
        summary: String.duplicate("x", 280),
        token: "secret",
        at: ~U[2026-05-22 12:00:00Z]
      })

    assert payload.id
    assert payload.analysis_id == "ana_test"
    assert payload.objective_id == "obj_test"
    assert payload.stage == "update"
    assert payload.status == "running"
    assert byte_size(payload.summary) == 240
    assert payload.at == "2026-05-22T12:00:00Z"
  end

  test "subscribe and broadcast deliver normalized progress messages" do
    analysis_id = "ana_progress_#{System.unique_integer([:positive])}"

    assert :ok = Progress.subscribe("local", analysis_id)

    assert :ok =
             Progress.broadcast("local", analysis_id, %{
               stage: "synthesis",
               summary: "Synthesizing"
             })

    assert_receive {:stocksage_progress, payload}, 500
    assert payload.analysis_id == analysis_id
    assert payload.stage == "synthesis"
    assert payload.summary == "Synthesizing"
  end

  test "disabled setting suppresses progress broadcast without breaking callers" do
    analysis_id = "ana_disabled_#{System.unique_integer([:positive])}"

    assert {:ok, _setting} =
             Settings.put("stocksage.web.progress_stream_enabled", false, %{audit?: false})

    assert :ok = Progress.subscribe("local", analysis_id)

    assert :ok =
             Progress.broadcast("local", analysis_id, %{stage: "synthesis", summary: "Hidden"})

    refute_receive {:stocksage_progress, _payload}, 100
  end

  test "persisted items summarize objective steps and terminal analysis state" do
    items =
      Progress.persisted_items(
        %{
          id: "ana_done",
          objective_id: "obj_done",
          status: "completed",
          summary: "AAPL completed.",
          updated_at: ~U[2026-05-22 12:01:00Z]
        },
        [
          %{
            id: "step_1",
            status: "completed",
            delegate_agent_id: "stocksage.market_context",
            result_summary: "Market context complete.",
            updated_at: ~U[2026-05-22 12:00:00Z]
          }
        ]
      )

    assert Enum.map(items, & &1.stage) == ["analyst", "completed"]
    assert Enum.map(items, & &1.summary) == ["Market context complete.", "AAPL completed."]
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
