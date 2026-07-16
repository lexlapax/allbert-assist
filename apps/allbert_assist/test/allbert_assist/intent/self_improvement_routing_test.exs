defmodule AllbertAssist.Intent.SelfImprovementRoutingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-self-improvement-routing-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    assert {:ok, _resolved} = Settings.put("self_improvement.enabled", true, %{audit?: false})

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "routes documented self-improvement intent phrase corpus" do
    [
      "show self-improvement suggestions",
      "what could you turn into a skill",
      "what could you turn into a workflow"
    ]
    |> Enum.with_index()
    |> Enum.each(fn {text, index} ->
      assert {:ok, response} =
               IntentAgent.respond(%{
                 text: text,
                 channel: :test,
                 user_id: "local",
                 operator_id: "local",
                 thread_id: "thr-self-improvement-#{index}",
                 session_id: "sess-self-improvement-#{index}",
                 input_signal_id: "sig-self-improvement-#{index}"
               })

      assert response.status == :completed
      assert response.decision.intent == :discover_patterns
      assert response.decision.selected_action == "discover_patterns"
      assert Enum.any?(response.actions, &(&1.name == "discover_patterns"))
    end)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
