defmodule AllbertAssist.Actions.TraceActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Trace.RecordTrace
  alias AllbertAssist.Intent.Candidate
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Memory
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace
  alias Jido.Signal

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_trace_enabled_env = System.get_env("ALLBERT_TRACE_ENABLED")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-trace-action-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)
    System.delete_env("ALLBERT_TRACE_ENABLED")

    on_exit(fn ->
      restore_env(Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_system_env("ALLBERT_TRACE_ENABLED", original_trace_enabled_env)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "records an enabled trace through the action boundary", %{root: root} do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace through action.")}, context())

    assert response.status == :completed
    assert response.trace_id =~ Path.join(root, "traces")
    assert File.exists?(response.trace_id)

    assert [
             %{
               name: "record_trace",
               status: :completed,
               permission: :memory_write,
               trace_metadata: %{trace_id: trace_id, error: nil}
             }
           ] = response.actions

    assert trace_id == response.trace_id

    trace = File.read!(trace_id)
    assert trace =~ "Skill metadata: direct-answer (built_in, trusted)"
    assert trace =~ "validation_status: :valid"
    assert trace =~ "## Security Metadata"
    assert trace =~ "risk: %{"
    assert trace =~ "policy:"
  end

  test "skips trace recording when tracing is disabled" do
    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace disabled.")}, context())

    assert response.status == :completed
    assert response.trace_id == nil
    assert [%{name: "record_trace", status: :skipped}] = response.actions
  end

  test "returns structured errors when trace writing fails" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    Application.put_env(:allbert_assist, Trace, writer: fn _attrs -> {:error, :disk_full} end)

    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace failure.")}, context())

    assert response.status == :error
    assert response.trace_id == nil
    assert response.error == :disk_full

    assert [%{name: "record_trace", status: :error, trace_metadata: %{error: :disk_full}}] =
             response.actions
  end

  test "renders v0.10 capability metadata in traces" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    cases = [
      {
        external_action(),
        ["## External Request Metadata", "Method: GET", "HTTP status: 200", "Body preview: ok"]
      },
      {
        package_action(),
        [
          "## Package Install Metadata",
          "Manager: npm",
          "Packages: left-pad@1.3.0",
          "Output preview: fake npm install"
        ]
      },
      {
        online_import_action(),
        [
          "## Online Skill Metadata",
          "Imported target: /tmp/allbert-cache/skills/demo",
          "Audit: passed"
        ]
      }
    ]

    Enum.each(cases, fn {action, expected_lines} ->
      assert {:ok, response} =
               RecordTrace.run(%{turn: turn_with_action(action)}, context())

      trace = File.read!(response.trace_id)
      Enum.each(expected_lines, &assert(trace =~ &1))
    end)
  end

  test "renders intent candidate metadata without leaking secret-like values" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    assert {:ok, selected} =
             Candidate.new(%{
               kind: :action,
               id: "direct_answer",
               action_name: "direct_answer",
               source: :deterministic,
               status: :selected,
               trace_metadata: %{api_key: "sk-test-secret", note: "safe"}
             })

    assert {:ok, decision} =
             Decision.new(%{
               intent: :direct_answer,
               selected_action: "direct_answer",
               trace_metadata: %{
                 intent_candidates: %{
                   selected: Candidate.to_map(selected),
                   rejected: [],
                   total: 1,
                   engine_version: "v0.19"
                 }
               },
               context: %{request: %{text: "Trace candidate redaction."}}
             })

    trace_turn =
      turn("Trace candidate redaction.")
      |> put_in([:response, :decision], decision)

    assert {:ok, response} = RecordTrace.run(%{turn: trace_turn}, context())

    trace = File.read!(response.trace_id)
    assert trace =~ "## Intent Candidates"
    assert trace =~ "[REDACTED]"
    refute trace =~ "sk-test-secret"
  end

  test "renders bounded memory intent candidates without entry bodies" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    memory_candidate = %{
      kind: :memory,
      id: "markdown_memory:/tmp/allbert/memory/preferences/example.md",
      source: :memory,
      score: 0.42,
      reason: "Indexed markdown memory matched the request.",
      trace_metadata: %{
        category: :preferences,
        timestamp: "2026-05-15T00:00:00Z",
        review_status: :kept,
        path: "/tmp/allbert/memory/preferences/example.md",
        match_reasons: ["keyword:concise"]
      }
    }

    assert {:ok, decision} =
             Decision.new(%{
               intent: :direct_answer,
               selected_action: "direct_answer",
               trace_metadata: %{
                 intent_candidates: %{
                   selected: %{
                     kind: :action,
                     id: "direct_answer",
                     source: :deterministic,
                     score: 1.0
                   },
                   memory: [
                     memory_candidate,
                     %{
                       memory_candidate
                       | id: "markdown_memory:/tmp/allbert/memory/preferences/second.md",
                         reason: "Second metadata-only memory candidate."
                     }
                   ],
                   rejected: [],
                   total: 2,
                   engine_version: "v0.19"
                 }
               },
               context: %{request: %{text: "Trace memory candidates."}}
             })

    trace_turn =
      turn("Trace memory candidates.")
      |> put_in([:response, :decision], decision)

    assert {:ok, response} = RecordTrace.run(%{turn: trace_turn}, context())

    trace = File.read!(response.trace_id)
    assert trace =~ "Memory:"
    assert trace =~ "category=preferences"
    assert trace =~ "review_status=kept"
    assert trace =~ "example.md"
    refute trace =~ "entry body content that should stay hidden"
  end

  test "renders memory review metadata without entry body content" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    trace_turn =
      turn("Review memory.")
      |> put_in([:response, :actions], [
        %{
          name: "review_memory_entry",
          status: :completed,
          permission: :memory_write,
          execution: :review,
          memory_path: "/tmp/allbert/memory/notes/reviewed.md",
          review_status: :kept,
          confirmation_id: "conf_123"
        },
        %{
          name: "delete_memory_entry",
          status: :needs_confirmation,
          permission: :memory_write,
          execution: :pending_confirmation,
          memory_path: "/tmp/allbert/memory/notes/delete.md",
          confirmation_id: "conf_456"
        }
      ])

    assert {:ok, response} = RecordTrace.run(%{turn: trace_turn}, context())

    trace = File.read!(response.trace_id)
    assert trace =~ "## Memory Review"
    assert trace =~ "review_memory_entry status=completed"
    assert trace =~ "review_status=kept"
    assert trace =~ "confirmation=conf_123"
    assert trace =~ "delete_memory_entry status=needs_confirmation"
    refute trace =~ "entry body content that should stay hidden"
  end

  test "renders bounded JidoBacked diagnostics only when debug trace is enabled" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    assert {:ok, response} =
             RecordTrace.run(%{turn: turn("Trace without Jido debug.")}, context())

    refute File.read!(response.trace_id) =~ "## Jido Debug"

    assert {:ok, _setting} =
             Settings.put("allbert.jido.debug_trace", true, %{
               actor: "local",
               channel: :test
             })

    assert {:ok, response} = RecordTrace.run(%{turn: turn("Trace with Jido debug.")}, context())
    trace = File.read!(response.trace_id)

    assert trace =~ "## Jido Debug"
    assert trace =~ "AllbertAssist.Confirmations.Store.Agent"
    assert trace =~ "AllbertAssist.Jobs.Scheduler.Agent"
    assert trace =~ "last_result="
    assert trace =~ "last_summary="
    refute trace =~ "api_key"
    refute trace =~ "token"
  end

  test "renders objective context inline and objective step details" do
    AllbertAssist.TraceTestSupport.enable_trace_default!()

    objective = %{
      id: "obj_trace",
      title: "Trace Objective",
      status: "running",
      step_count: 1,
      steps: [
        %{
          id: "step_trace",
          status: "blocked",
          kind: "action",
          candidate_action: "StockSage.Actions.RunAnalysis",
          confirmation_id: "conf_trace"
        }
      ]
    }

    trace_turn =
      "Trace objective context."
      |> turn()
      |> put_in([:response, :objective], objective)

    assert {:ok, response} = RecordTrace.run(%{turn: trace_turn}, context())
    trace = File.read!(response.trace_id)

    assert trace =~ "## Response\n\nRuntime response: Trace objective context.\n\n### Objective"
    assert trace =~ "## Actions\n\n```elixir"
    assert trace =~ "## Confirmation Metadata"
    assert trace =~ "- Objective: Trace Objective"
    assert trace =~ "## Objective Steps"

    assert trace =~
             "- Step: step_trace status=blocked kind=action action=StockSage.Actions.RunAnalysis confirmation=conf_trace"
  end

  defp turn(text) do
    {:ok, input_signal} =
      Signal.new(
        "allbert.input.received",
        %{text: text},
        source: "/allbert/channels/test",
        subject: "local"
      )

    {:ok, response_signal} =
      Signal.new(
        "allbert.agent.responded",
        %{message: "Runtime response: #{text}"},
        source: "/allbert/runtime",
        subject: "local"
      )

    %{
      input_signal: input_signal,
      response_signal: response_signal,
      request: %{text: text, channel: :test, operator_id: "local", metadata: %{}},
      response: %{
        message: "Runtime response: #{text}",
        status: :completed,
        actions: [
          %{
            name: "direct_answer",
            skill_metadata: %{
              selected_skill: "direct-answer",
              source_scope: :built_in,
              trust_status: :trusted,
              capability_contract: %{
                validation_status: :valid,
                execution_eligible?: true
              }
            },
            permission_decision:
              PermissionGate.authorize(:read_only, %{
                request: %{operator_id: "local", channel: :test, input_signal_id: input_signal.id},
                selected_action: "direct_answer"
              })
          }
        ],
        diagnostics: []
      },
      agent: AllbertAssist.Agents.IntentAgent
    }
  end

  defp turn_with_action(action) do
    turn("Trace v0.10 capability metadata.")
    |> put_in([:response, :actions], [action])
  end

  defp external_action do
    %{
      name: "external_network_request",
      status: :completed,
      permission_decision: permission_decision(:external_network),
      request: %{
        method: "GET",
        url: "https://example.com/status",
        profile: "default",
        host: "example.com",
        path: "/status",
        timeout_ms: 5000,
        max_response_bytes: 1024,
        allow_redirects?: false,
        retry_policy: "none"
      },
      result: %{
        status: :completed,
        http_status: 200,
        duration_ms: 8,
        body_preview: "ok",
        response_body_bytes: 2,
        truncated?: false
      }
    }
  end

  defp package_action do
    %{
      name: "run_package_install",
      status: :completed,
      permission_decision: permission_decision(:package_install),
      package_install: %{
        manager: "npm",
        packages: ["left-pad@1.3.0"],
        resolved_target_root: "/tmp/allbert-package-target",
        execution_argv_preview: ["npm", "install", "left-pad@1.3.0", "--ignore-scripts"],
        execution_available?: true
      },
      result: %{
        status: :completed,
        exit_status: 0,
        stdout_preview: "fake npm install",
        output_bytes: 16,
        truncated?: false
      }
    }
  end

  defp online_import_action do
    %{
      name: "import_online_skill",
      status: :completed,
      permission_decision: permission_decision(:online_skill_import),
      online_skill_import: %{
        status: :imported_disabled,
        source: %{id: "skills_sh"},
        target_root: "/tmp/allbert-cache/skills/demo",
        manifest_path: "/tmp/allbert-cache/skills/_sources/demo.json",
        audit: %{status: :passed}
      }
    }
  end

  defp permission_decision(permission) do
    PermissionGate.authorize(permission, %{
      request: %{operator_id: "local", channel: :test, input_signal_id: "sig-trace"},
      selected_action: to_string(permission)
    })
  end

  defp context do
    %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig-trace"}}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
