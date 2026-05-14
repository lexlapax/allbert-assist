defmodule AllbertAssist.Actions.AppActionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Runner

  test "list_apps exposes redacted summaries through the action runner" do
    original_logger_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: original_logger_level)
    end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, response} = Runner.run("list_apps", %{}, context())

        assert response.status == :completed
        assert response.runner_metadata.action_name == "list_apps"

        app_ids = Enum.map(response.apps, & &1.app_id)
        assert :allbert in app_ids
        assert :stocksage in app_ids

        assert Enum.all?(response.apps, &Map.has_key?(&1, :action_count))
        refute inspect(response.apps) =~ "skill_paths"
        refute inspect(response.apps) =~ "child_pid"
      end)

    assert log =~ "allbert.action.requested"
    assert log =~ "allbert.action.completed"
  end

  test "show_app returns full registered app detail without supervisor internals" do
    assert {:ok, response} = Runner.run("show_app", %{app_id: "allbert"}, context())

    assert response.status == :completed
    assert response.app.app_id == :allbert
    assert response.app.display_name == "Allbert"
    assert response.app.action_names == []
    assert response.app.skill_paths == []
    assert response.app.surfaces == []
    refute inspect(response.app) =~ "child_pid"
  end

  test "show_app reports unknown apps without creating atoms" do
    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"

    assert {:ok, response} = Runner.run("show_app", %{app_id: unknown}, context())

    assert response.status == :not_found
    assert response.error == :unknown_app

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
  end

  defp context do
    %{request: %{input_signal_id: "input-sig", operator_id: "local", user_id: "local"}}
  end
end
