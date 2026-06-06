defmodule AllbertAssist.SelfImprovement.TraceIndexTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.SelfImprovement.TraceIndex
  alias AllbertAssist.Settings

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_MEMORY_ROOT",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_memory_config = Application.get_env(:allbert_assist, AllbertAssist.Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, AllbertAssist.Memory)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, AllbertAssist.Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(AllbertAssist.Memory, original_memory_config)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "query is disabled by default and does not read trace files", %{home: home} do
    write_trace(home, "disabled.md", %{
      user_id: "alice",
      app_id: "browser",
      input: "Repeat this plan"
    })

    assert {:ok,
            %{
              enabled?: false,
              entries_scanned: 0,
              patterns: [],
              diagnostics: diagnostics
            }} = TraceIndex.index()

    assert Enum.any?(diagnostics, &(&1.reason == :self_improvement_disabled))
    assert Enum.any?(diagnostics, &(&1.reason == :trace_index_disabled))
    assert {:ok, []} = TraceIndex.query()
  end

  test "query groups repeated prompts and action chains by user and app scope", %{home: home} do
    enable_index()

    for index <- 1..3 do
      write_trace(home, "alice-browser-#{index}.md", %{
        user_id: "alice",
        app_id: "browser",
        input: "Summarize this release plan",
        action: "browser_extract"
      })
    end

    write_trace(home, "bob-browser.md", %{
      user_id: "bob",
      app_id: "browser",
      input: "Summarize this release plan",
      action: "browser_extract"
    })

    assert {:ok, patterns} = TraceIndex.query(%{user_id: "alice", app_id: "browser"})

    assert %{count: 3, scope: %{user_ids: ["alice"], app_ids: ["browser"]}} =
             Enum.find(patterns, &(&1.pattern_type == :repeated_prompt))

    assert %{count: 3, actions: ["browser_extract"]} =
             Enum.find(patterns, &(&1.pattern_type == :action_chain))

    assert {:ok, []} = TraceIndex.query(%{user_id: "bob", app_id: "browser"})
  end

  test "redacts prompt samples and honors min repetitions", %{home: home} do
    enable_index()
    set_min_repetitions(2)

    for index <- 1..2 do
      write_trace(home, "secret-correction-#{index}.md", %{
        user_id: "alice",
        app_id: "workspace",
        input:
          "Actually fix that provider key sk-testsecret123456 and secret://providers/openai/api_key",
        action: "memory_write"
      })
    end

    assert {:ok, patterns} = TraceIndex.query(%{user_id: "alice", app_id: "workspace"})
    rendered = inspect(patterns)

    refute rendered =~ "sk-testsecret123456"
    refute rendered =~ "secret://providers/openai/api_key"
    assert rendered =~ "[REDACTED]"
    assert rendered =~ "[SECRET_REF]"

    assert %{count: 2} = Enum.find(patterns, &(&1.pattern_type == :repeated_prompt))
    assert %{count: 2} = Enum.find(patterns, &(&1.pattern_type == :correction))
  end

  test "indexes repeated failed intents without granting authority", %{home: home} do
    enable_index()
    set_min_repetitions(2)

    for index <- 1..2 do
      write_trace(home, "failed-#{index}.md", %{
        user_id: "alice",
        app_id: "workspace",
        status: "denied",
        input: "Connect and run the unsupported resource workflow",
        action: "unsupported_resource_workflow"
      })
    end

    assert {:ok, [%{pattern_type: :failed_intent, count: 2, status: "denied"}]} =
             TraceIndex.query(%{
               user_id: "alice",
               app_id: "workspace",
               pattern_type: :failed_intent
             })
  end

  defp enable_index do
    assert {:ok, _resolved} = Settings.put("self_improvement.enabled", true, %{audit?: false})

    assert {:ok, _resolved} =
             Settings.put("self_improvement.trace_index.enabled", true, %{audit?: false})
  end

  defp set_min_repetitions(value) do
    assert {:ok, _resolved} =
             Settings.put("self_improvement.trace_index.min_repetitions", value, %{audit?: false})
  end

  defp write_trace(home, name, attrs) do
    trace_root = Path.join([home, "memory", "traces"])
    File.mkdir_p!(trace_root)

    path = Path.join(trace_root, name)
    user_id = Map.fetch!(attrs, :user_id)
    app_id = Map.fetch!(attrs, :app_id)
    status = Map.get(attrs, :status, "ok")
    input = Map.fetch!(attrs, :input)
    action = Map.get(attrs, :action, "browser_extract")

    File.write!(path, """
    ## Runtime Turn

    - Trace format: v0.01-m6
    - Channel: test
    - User: #{user_id}
    - Active app: #{app_id}
    - Status: #{status}
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

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "allbert_trace_index_#{label}_#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
