defmodule AllbertAssist.Actions.SelfImprovementActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-self-improvement-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "discover_patterns is registered as read-only internal action" do
    assert {:ok, module} = Registry.resolve("discover_patterns")
    assert module == AllbertAssist.Actions.SelfImprovement.DiscoverPatterns

    assert {:ok, capability} = Registry.capability("discover_patterns")
    assert capability.permission == :read_only
    assert capability.exposure == :internal
    assert capability.confirmation == :not_required
  end

  test "discover_patterns writes only inert advisory suggestions from trace fixtures", %{
    root: root
  } do
    enable_self_improvement()

    for index <- 1..3 do
      write_trace(root, "release-plan-#{index}.md", %{
        user_id: "alice",
        app_id: "workspace",
        input: "Summarize this release plan",
        action: "browser_extract"
      })
    end

    context = %{actor: "alice", user_id: "alice", channel: :test, active_app: "workspace"}

    assert {:ok, response} =
             Runner.run(
               "discover_patterns",
               %{query: "show self-improvement suggestions"},
               context
             )

    assert response.status == :completed
    assert response.permission_decision.permission == :read_only
    assert Enum.all?(response.actions, &(&1.permission == :read_only))
    assert length(response.suggestions) >= 1

    persisted = Discovery.list_suggestions(status: "pending", provenance: "self_improvement")

    assert Enum.any?(persisted, &(&1.suggestion_type == "trace_to_skill"))
    assert Enum.any?(persisted, &(&1.suggestion_type == "trace_to_workflow"))

    assert Enum.all?(persisted, fn suggestion ->
             suggestion.candidate_id == nil and
               suggestion.provenance == "self_improvement" and
               suggestion.status == "pending" and
               suggestion.draft_id == nil
           end)
  end

  defp enable_self_improvement do
    assert {:ok, _resolved} = Settings.put("self_improvement.enabled", true, %{audit?: false})

    assert {:ok, _resolved} =
             Settings.put("self_improvement.trace_index.enabled", true, %{audit?: false})
  end

  defp write_trace(root, name, attrs) do
    trace_root = Path.join([root, "memory", "traces"])
    File.mkdir_p!(trace_root)

    path = Path.join(trace_root, name)
    user_id = Map.fetch!(attrs, :user_id)
    app_id = Map.fetch!(attrs, :app_id)
    input = Map.fetch!(attrs, :input)
    action = Map.fetch!(attrs, :action)

    File.write!(path, """
    ## Runtime Turn

    - Trace format: v0.01-m6
    - Channel: test
    - User: #{user_id}
    - Active app: #{app_id}
    - Status: ok
    - Selected action: #{action}

    ## Input

    #{input}

    ## Actions

    ```elixir
    [%{name: "#{action}"}]
    ```
    """)

    path
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
