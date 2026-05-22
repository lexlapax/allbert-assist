defmodule StockSage.Actions.RunAnalysis do
  @moduledoc """
  StockSage analysis execution through the native specialist graph or the
  explicitly requested Python bridge.

  On first call the action creates a durable confirmation record and returns
  `:needs_confirmation`. On the approved resume path (`approve_confirmation`
  invokes this action with `confirmation.approved? = true`), the action
  re-checks Security Central, runs the requested engine, and persists the
  result rows. Native failures, bridge crashes, timeouts, and disabled-bridge
  cases are surfaced as structured errors.

  Bridge code lives under `./plugins/stocksage/`. Allbert core does not
  import bridge internals.

  ## Substrate (v0.22 M2 audit closeout)

  This module is a plain `Jido.Action` (not a `Jido.Agent`). It owns no
  state machine; the durable confirmation row owns the resume contract.

  ## `approval_resume?/1` — internal API only (v0.22 M2 audit moderate gap 6)

  The private `approval_resume?/1` clause matches on
  `%{confirmation: %{approved?: true}}` in the action context. This is an
  **internal** convention used by
  `AllbertAssist.Actions.Confirmations.ApproveConfirmation` when it
  resumes a previously-pending action through the action runner. External
  callers must not forge this context shape to bypass the confirmation
  flow:

  - Production callers reach `RunAnalysis` through
    `AllbertAssist.Actions.Runner.run/3` with no `:confirmation` key —
    the action then creates a pending confirmation and returns
    `:needs_confirmation`.
  - The only legitimate caller that supplies `confirmation.approved? =
    true` is `ApproveConfirmation`, which has already re-checked Security
    Central and resolved the durable confirmation record before resuming.
  - Tests may supply the shape directly to exercise the resume branch
    without going through the full confirmation lifecycle.

  Hardening (caller verification, signed resume marker, or
  per-confirmation resume token) is deferred to v0.23 Jido State-Machine
  Convergence, where `Confirmations.Store` becomes a `Jido.Agent` with
  lifecycle hooks suitable for verified-resume gating. v0.22 audit
  closure (moderate gap 6) explicitly documents this as internal-API-only
  rather than tightening it now.
  """

  use Jido.Action,
    name: "run_analysis",
    description: "Run a StockSage analysis for a ticker.",
    category: "stocksage",
    tags: ["stocksage", "analysis", "confirmation"],
    schema: [
      ticker: [type: :string, required: true],
      analysis_date: [type: :string, required: true],
      engine: [type: :string, required: false],
      compare_python: [type: :boolean, required: false],
      evidence_mode: [type: :string, required: false],
      user_id: [type: :string, required: false],
      queue_entry_id: [type: :string, required: false],
      source_analysis_id: [type: :string, required: false],
      objective_id: [type: :string, required: false],
      step_id: [type: :string, required: false],
      thread_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      # When true, the bridge runs the deterministic stub path regardless
      # of whether `tradingagents` is importable. Stub responses are
      # labeled `stub: true` in the persisted detail row. Used by tests,
      # smoke flows, and dev environments without LLM credentials.
      force_stub: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals, as: AllbertSignals
  alias AllbertAssist.Workspace.Emitters, as: WorkspaceEmitters
  alias Jido.Signal
  alias StockSage.Actions
  alias StockSage.Agents.LLM
  alias StockSage.Agents.NativeCoordinator
  alias StockSage.Analyses
  alias StockSage.Bridge.Protocol
  alias StockSage.Progress
  alias StockSage.Queue
  alias StockSage.SurfaceNodes
  alias StockSage.TraderBridge

  @ticker_pattern ~r/^[A-Za-z0-9._-]{1,10}$/
  @max_ticker 10
  @summary_max 500
  @failure_summary_max 200
  @max_analysis_date_offset_days 730
  # Default 1 MiB cap for persisted detail bodies when
  # `stocksage.bridge_max_output_bytes` is unavailable. v0.22 unifies the
  # in-flight bridge bound and the persisted detail bound on this single
  # setting per audit feedback.
  @default_detail_max 1_048_576
  @detail_content_max 16_000
  @terminal_objective_statuses ~w[abandoned cancelled completed failed]
  @signal_analysis_requested "allbert.stocksage.analysis_requested"
  @signal_analysis_completed "allbert.stocksage.analysis_completed"
  @signal_analysis_failed "allbert.stocksage.analysis_failed"

  def capability do
    Actions.capability(:stocksage_analyze, %{
      confirmation: :required,
      exposure: :agent,
      execution_mode: :native_agent_graph,
      risk_tier: :high,
      resumable?: true
    })
  end

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:stocksage_analyze, context)

    with {:ok, ticker} <- normalize_ticker(Actions.field(params, :ticker)),
         {:ok, analysis_date} <- normalize_analysis_date(Actions.field(params, :analysis_date)),
         engine <- normalize_engine(params),
         {:ok, user_id} <- Actions.user_id(params, context) do
      validated = %{
        ticker: ticker,
        analysis_date: analysis_date,
        engine: engine,
        evidence_mode: normalize_evidence_mode(Actions.field(params, :evidence_mode)),
        user_id: user_id,
        queue_entry_id: blank(Actions.field(params, :queue_entry_id)),
        source_analysis_id: blank(Actions.field(params, :source_analysis_id)),
        objective_id:
          blank(Actions.field(params, :objective_id) || Actions.field(context, :objective_id)),
        step_id: blank(Actions.field(params, :step_id) || Actions.field(context, :step_id)),
        thread_id: blank(Actions.field(params, :thread_id) || Actions.field(context, :thread_id)),
        session_id:
          blank(Actions.field(params, :session_id) || Actions.field(context, :session_id)),
        force_stub: normalize_bool(Actions.field(params, :force_stub))
      }

      dispatch(validated, context, permission_decision)
    else
      {:error, :invalid_ticker} ->
        invalid(permission_decision, :invalid_ticker, "Invalid ticker symbol.")

      {:error, :invalid_analysis_date} ->
        invalid(permission_decision, :invalid_analysis_date, "Invalid ISO-8601 analysis date.")

      {:error, :missing_user_id} ->
        Actions.missing_user("run_analysis", :stocksage_analyze, permission_decision)
    end
  end

  defp dispatch(validated, context, permission_decision) do
    cond do
      native_engine?(validated.engine) and not native_engine_enabled?() ->
        native_disabled(validated, permission_decision)

      python_engine?(validated.engine) and not python_comparison_enabled?() ->
        python_comparison_disabled(validated, permission_decision)

      python_engine?(validated.engine) and not bridge_enabled?() ->
        bridge_disabled(validated, permission_decision)

      approval_resume?(context) ->
        run_after_approval(validated, context, permission_decision)

      not PermissionGate.allowed?(permission_decision) and
          permission_decision.requires_confirmation ->
        request_confirmation(validated, context, permission_decision)

      PermissionGate.allowed?(permission_decision) ->
        # The :stocksage_analyze floor is :needs_confirmation, so this branch
        # only fires if Security Central allows the call directly (e.g., in
        # internal/test contexts that already approved via context).
        run_after_approval(validated, context, permission_decision)

      true ->
        denied(validated, permission_decision)
    end
  end

  defp request_confirmation(validated, context, permission_decision) do
    case Confirmations.create(%{
           origin: origin(context, validated),
           objective_id: validated.objective_id,
           step_id: validated.step_id,
           source_signal_id:
             Actions.field(context, :input_signal_id) ||
               Actions.field(context, :runner_requested_signal_id),
           source_trace_id: Actions.field(context, :trace_id),
           target_action: %{name: "run_analysis", module: inspect(__MODULE__)},
           target_permission: :stocksage_analyze,
           target_execution_mode: target_execution_mode(validated.engine),
           security_decision: permission_decision,
           params_summary: %{
             ticker: validated.ticker,
             analysis_date: Date.to_iso8601(validated.analysis_date),
             engine: validated.engine,
             evidence_mode: validated.evidence_mode,
             user_id: validated.user_id,
             queue_entry_id: validated.queue_entry_id,
             source_analysis_id: validated.source_analysis_id,
             objective_id: validated.objective_id,
             step_id: validated.step_id,
             objective_title: get_in(context, [:objective, :title]),
             objective_status: get_in(context, [:objective, :status]),
             force_stub: validated.force_stub,
             disclosure: confirmation_disclosure(validated)
           },
           resume_params_ref: %{
             ticker: validated.ticker,
             analysis_date: Date.to_iso8601(validated.analysis_date),
             engine: validated.engine,
             evidence_mode: validated.evidence_mode,
             user_id: validated.user_id,
             queue_entry_id: validated.queue_entry_id,
             source_analysis_id: validated.source_analysis_id,
             objective_id: validated.objective_id,
             step_id: validated.step_id,
             thread_id: validated.thread_id,
             session_id: validated.session_id,
             force_stub: validated.force_stub
           }
         }) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "StockSage analysis confirmation required. Confirmation id: #{confirmation["id"]}.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             Actions.action(
               "run_analysis",
               :needs_confirmation,
               :stocksage_analyze,
               permission_decision,
               %{
                 confirmation_id: confirmation["id"],
                 ticker: validated.ticker,
                 analysis_date: Date.to_iso8601(validated.analysis_date),
                 engine: validated.engine,
                 evidence_mode: validated.evidence_mode,
                 user_id: validated.user_id,
                 queue_entry_id: validated.queue_entry_id,
                 source_analysis_id: validated.source_analysis_id,
                 objective_id: validated.objective_id,
                 step_id: validated.step_id,
                 risk_tier: :high
               }
             )
           ]
         }}

      {:error, reason} ->
        error(permission_decision, :confirmation_create_failed, reason)
    end
  end

  defp run_after_approval(validated, context, permission_decision) do
    with :ok <- ensure_queue_entry(validated) do
      started_at = DateTime.utc_now()
      emit_analysis_signal(@signal_analysis_requested, requested_payload(validated, context))

      case validated.engine do
        "native" ->
          run_native_after_approval(validated, context, permission_decision, started_at)

        engine when engine in ["python", "tradingagents"] ->
          run_python_after_approval(validated, context, permission_decision, started_at)

        "both" ->
          run_parity_after_approval(validated, context, permission_decision, started_at)

        engine ->
          persist_failure(
            validated,
            {:unsupported_engine, engine},
            context,
            permission_decision,
            started_at
          )
      end
    else
      {:error, queue_reason} ->
        queue_entry_invalid(validated, permission_decision, queue_reason)
    end
  end

  defp run_native_after_approval(validated, context, permission_decision, started_at) do
    with {:ok, validated, context} <- ensure_native_objective(validated, context),
         :ok <- LLM.preflight(),
         {:ok, result} <- NativeCoordinator.analyze(native_request(validated, context)) do
      persist_success(validated, result, context, permission_decision, started_at)
    else
      {:error, reason} ->
        persist_failure(validated, reason, context, permission_decision, started_at)
    end
  end

  defp run_python_after_approval(validated, context, permission_decision, started_at) do
    analyze_params =
      %{
        ticker: validated.ticker,
        analysis_date: Date.to_iso8601(validated.analysis_date),
        engine: bridge_engine(validated.engine)
      }
      |> maybe_put(:force_stub, validated.force_stub)

    case TraderBridge.analyze(analyze_params) do
      {:ok, result} ->
        persist_success(validated, result, context, permission_decision, started_at)

      {:error, reason} ->
        persist_failure(validated, reason, context, permission_decision, started_at)
    end
  end

  defp run_parity_after_approval(validated, context, permission_decision, started_at) do
    with {:ok, validated, context} <- ensure_native_objective(validated, context),
         {:ok, result} <- NativeCoordinator.parity_run(native_request(validated, context)) do
      persist_success(validated, result, context, permission_decision, started_at)
    else
      {:error, reason} ->
        persist_failure(validated, reason, context, permission_decision, started_at)
    end
  end

  defp ensure_native_objective(%{objective_id: objective_id} = validated, context)
       when is_binary(objective_id) and objective_id != "" do
    {:ok, validated, context}
  end

  defp ensure_native_objective(validated, context) do
    attrs = %{
      user_id: validated.user_id,
      source_thread_id: validated.thread_id,
      session_id: validated.session_id,
      active_app: "stocksage",
      title: "Analyze #{validated.ticker} native",
      objective:
        "Produce a native StockSage analysis for #{validated.ticker} on " <>
          Date.to_iso8601(validated.analysis_date),
      acceptance_criteria: %{
        "kind" => "stocksage_native_analysis",
        "ticker" => validated.ticker,
        "analysis_date" => Date.to_iso8601(validated.analysis_date),
        "engine" => "native"
      },
      source_intent: "stocksage.run_analysis"
    }

    case Objectives.create_objective(attrs) do
      {:ok, objective} ->
        validated = %{validated | objective_id: objective.id}
        context = Map.put(context, :objective_id, objective.id)
        {:ok, validated, context}

      {:error, reason} ->
        {:error, {:objective_create_failed, errors_on(reason)}}
    end
  end

  defp native_request(validated, context) do
    step_ref = objective_step_ref(validated)

    %{
      request_id: confirmation_id(context),
      ticker: validated.ticker,
      analysis_date: Date.to_iso8601(validated.analysis_date),
      user_id: validated.user_id,
      operator_id: validated.user_id,
      objective_id: step_ref.objective_id,
      step_id: step_ref.step_id,
      thread_id: validated.thread_id || Actions.field(context, :thread_id),
      session_id: validated.session_id || Actions.field(context, :session_id),
      trace_id: Actions.field(context, :trace_id),
      evidence_mode: validated.evidence_mode,
      fixture: validated.evidence_mode == "fixture",
      force_stub: validated.force_stub,
      parent: %{
        permission: :stocksage_analyze,
        approved?: true,
        confirmation_id: confirmation_id(context)
      }
    }
    |> drop_nil_values()
  end

  defp objective_step_ref(%{objective_id: objective_id, user_id: user_id, step_id: step_id})
       when is_binary(objective_id) and objective_id != "" do
    case Objectives.get_objective(user_id, objective_id) do
      {:ok, %{status: status}} when status in @terminal_objective_statuses ->
        %{objective_id: nil, step_id: nil}

      {:ok, _objective} ->
        %{objective_id: objective_id, step_id: step_id}

      {:error, :not_found} ->
        %{objective_id: nil, step_id: nil}
    end
  end

  defp objective_step_ref(_validated), do: %{objective_id: nil, step_id: nil}

  # `validated.force_stub` is always a boolean (normalized via
  # `normalize_bool/1`), so the only "skip" case is `false`. `nil` is
  # unreachable here; dialyzer flagged a dead pattern when it was present.
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_queue_entry(%{queue_entry_id: nil}), do: :ok
  defp ensure_queue_entry(%{queue_entry_id: ""}), do: :ok

  defp ensure_queue_entry(%{queue_entry_id: queue_id, user_id: user_id})
       when is_binary(queue_id) and queue_id != "" do
    # `Queue.get_entry/2` returns `{:ok, entry} | {:error, :not_found}`;
    # no other error shape is reachable, which is why the dialyzer-clean
    # match list below has only those two arms.
    case Queue.get_entry(user_id, queue_id) do
      {:ok, entry} ->
        cond do
          entry.user_id != user_id ->
            {:error, :queue_entry_not_found}

          entry.status in ["queued", "running"] ->
            :ok

          true ->
            {:error, {:queue_entry_already_consumed, entry.status}}
        end

      {:error, :not_found} ->
        {:error, :queue_entry_not_found}
    end
  end

  defp ensure_queue_entry(_other), do: :ok

  defp queue_entry_invalid(validated, permission_decision, reason) do
    emit_analysis_signal(@signal_analysis_failed, %{
      ticker: validated.ticker,
      analysis_date: Date.to_iso8601(validated.analysis_date),
      engine: validated.engine,
      evidence_mode: validated.evidence_mode,
      user_id: validated.user_id,
      thread_id: validated.thread_id,
      session_id: validated.session_id,
      queue_entry_id: validated.queue_entry_id,
      source_analysis_id: validated.source_analysis_id,
      objective_id: validated.objective_id,
      step_id: validated.step_id,
      error: queue_reason_to_string(reason)
    })

    {:ok,
     %{
       message:
         "StockSage analysis aborted before bridge call: #{queue_reason_to_string(reason)}.",
       status: :error,
       error: :queue_entry_not_found,
       detail: queue_reason_to_string(reason),
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{
             error: :queue_entry_not_found,
             ticker: validated.ticker,
             analysis_date: Date.to_iso8601(validated.analysis_date),
             engine: validated.engine,
             queue_entry_id: validated.queue_entry_id,
             source_analysis_id: validated.source_analysis_id,
             objective_id: validated.objective_id,
             step_id: validated.step_id,
             reason: queue_reason_to_string(reason)
           }
         )
       ]
     }}
  end

  defp queue_reason_to_string({:queue_entry_already_consumed, status}),
    do: "queue entry already consumed (status=#{status})"

  defp queue_reason_to_string(:queue_entry_not_found), do: "queue entry not found"

  defp persist_success(validated, result, context, permission_decision, started_at) do
    duration_ms = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
    summary = bounded(result_field(result, :summary), @summary_max)
    truncated? = result_field(result, :truncated, false)

    analysis_attrs = %{
      user_id: validated.user_id,
      symbol: validated.ticker,
      analysis_date: validated.analysis_date,
      status: "completed",
      source: analysis_source(validated.engine),
      engine: persisted_engine(validated.engine),
      recommendation: result_field(result, :recommendation),
      summary: summary,
      thread_id: Actions.field(context, :thread_id),
      session_id: Actions.field(context, :session_id),
      input_signal_id: Actions.field(context, :input_signal_id),
      trace_id: Actions.field(context, :trace_id),
      request_id: confirmation_id(context),
      objective_id: validated.objective_id,
      step_id: validated.step_id,
      metadata:
        %{
          "engine" => validated.engine,
          "duration_ms" => duration_ms,
          "truncated" => truncated?,
          "queue_entry_id" => validated.queue_entry_id,
          "source_analysis_id" => validated.source_analysis_id,
          "objective_id" => validated.objective_id,
          "step_id" => validated.step_id,
          "parity_pass" => get_in(result_field(result, :parity_diff, %{}), ["parity_pass"])
        }
        |> drop_nil_values(),
      parity_diff: parity_diff_json(result)
    }

    # v0.22 audit closeout (Gap 1 — stub-mode visibility): surface the
    # `stub` flag in the action's response, runner metadata, completed
    # signal, and trace section so operators inspecting any of those
    # surfaces immediately see whether a row came from a real
    # TradingAgents propagate call or from the deterministic stub.
    stub? = result_field(result, :stub, false)

    case Analyses.create_analysis(analysis_attrs) do
      {:ok, analysis} ->
        case SurfaceNodes.completed(
               analysis,
               validated,
               result,
               context,
               summary,
               duration_ms,
               stub?,
               truncated?
             ) do
          {:ok, surface_nodes} ->
            write_detail(analysis, validated, result, truncated?)
            update_queue(validated, analysis, :completed, started_at)

            emit_analysis_signal(@signal_analysis_completed, %{
              analysis_id: analysis.id,
              ticker: validated.ticker,
              analysis_date: Date.to_iso8601(validated.analysis_date),
              engine: validated.engine,
              user_id: validated.user_id,
              thread_id: validated.thread_id || Actions.field(context, :thread_id),
              session_id: validated.session_id || Actions.field(context, :session_id),
              queue_entry_id: validated.queue_entry_id,
              source_analysis_id: validated.source_analysis_id,
              objective_id: validated.objective_id,
              step_id: validated.step_id,
              duration_ms: duration_ms,
              bridge_duration_ms:
                if(python_engine?(validated.engine), do: duration_ms, else: nil),
              truncated: truncated?,
              stub: stub?,
              summary: summary,
              native_trace: native_trace_metadata(validated, result)
            })

            Progress.broadcast(validated.user_id, analysis.id, %{
              objective_id: validated.objective_id,
              stage: "completed",
              status: "completed",
              summary: summary,
              at: DateTime.utc_now()
            })

            {:ok,
             %{
               message:
                 "StockSage analysis for #{validated.ticker} on #{Date.to_iso8601(validated.analysis_date)} completed.",
               status: :completed,
               permission_decision: permission_decision,
               analysis_id: analysis.id,
               ticker: analysis.symbol,
               analysis_date: Date.to_iso8601(validated.analysis_date),
               engine: validated.engine,
               summary: summary,
               surface_nodes: surface_nodes,
               truncated: truncated?,
               stub: stub?,
               parity_diff: result_field(result, :parity_diff),
               duration_ms: duration_ms,
               bridge_duration_ms:
                 if(python_engine?(validated.engine), do: duration_ms, else: nil),
               objective_id: validated.objective_id,
               step_id: validated.step_id,
               actions: [
                 Actions.action(
                   "run_analysis",
                   :completed,
                   :stocksage_analyze,
                   permission_decision,
                   %{
                     analysis_id: analysis.id,
                     ticker: analysis.symbol,
                     analysis_date: Date.to_iso8601(validated.analysis_date),
                     engine: validated.engine,
                     duration_ms: duration_ms,
                     bridge_duration_ms:
                       if(python_engine?(validated.engine), do: duration_ms, else: nil),
                     truncated: truncated?,
                     stub: stub?,
                     parity_diff: result_field(result, :parity_diff),
                     native_trace: native_trace_metadata(validated, result),
                     queue_entry_id: validated.queue_entry_id,
                     source_analysis_id: validated.source_analysis_id,
                     objective_id: validated.objective_id,
                     step_id: validated.step_id,
                     summary: summary
                   }
                 )
               ]
             }}

          {:error, diagnostics} ->
            error(permission_decision, :surface_node_validation_failed, diagnostics)
        end

      {:error, changeset} ->
        error(permission_decision, :persist_failed, errors_on(changeset))
    end
  end

  defp persist_failure(validated, reason, context, permission_decision, started_at) do
    duration_ms = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
    summary = bounded(Protocol.bounded_reason(reason), @failure_summary_max)

    analysis_attrs = %{
      user_id: validated.user_id,
      symbol: validated.ticker,
      analysis_date: validated.analysis_date,
      status: "failed",
      source: analysis_source(validated.engine),
      engine: persisted_engine(validated.engine),
      summary: summary,
      thread_id: Actions.field(context, :thread_id),
      session_id: Actions.field(context, :session_id),
      input_signal_id: Actions.field(context, :input_signal_id),
      trace_id: Actions.field(context, :trace_id),
      request_id: confirmation_id(context),
      objective_id: validated.objective_id,
      step_id: validated.step_id,
      metadata: %{
        "engine" => validated.engine,
        "duration_ms" => duration_ms,
        "error" => Protocol.bounded_reason(reason),
        "queue_entry_id" => validated.queue_entry_id,
        "source_analysis_id" => validated.source_analysis_id,
        "objective_id" => validated.objective_id,
        "step_id" => validated.step_id
      }
    }

    {analysis_id, persistence_error} =
      case Analyses.create_analysis(analysis_attrs) do
        {:ok, analysis} -> {analysis.id, nil}
        {:error, changeset} -> {nil, errors_on(changeset)}
      end

    case SurfaceNodes.failed(
           analysis_id,
           validated,
           context,
           Protocol.bounded_reason(reason),
           duration_ms
         ) do
      {:ok, surface_nodes} ->
        update_queue(validated, %{id: analysis_id}, :failed, started_at, reason)

        emit_analysis_signal(@signal_analysis_failed, %{
          analysis_id: analysis_id,
          ticker: validated.ticker,
          analysis_date: Date.to_iso8601(validated.analysis_date),
          engine: validated.engine,
          user_id: validated.user_id,
          thread_id: validated.thread_id || Actions.field(context, :thread_id),
          session_id: validated.session_id || Actions.field(context, :session_id),
          queue_entry_id: validated.queue_entry_id,
          source_analysis_id: validated.source_analysis_id,
          objective_id: validated.objective_id,
          step_id: validated.step_id,
          duration_ms: duration_ms,
          bridge_duration_ms: if(python_engine?(validated.engine), do: duration_ms, else: nil),
          error: Protocol.bounded_reason(reason)
        })

        Progress.broadcast(validated.user_id, analysis_id, %{
          objective_id: validated.objective_id,
          stage: "failed",
          status: "failed",
          summary: summary,
          at: DateTime.utc_now()
        })

        {:ok,
         %{
           message:
             "StockSage analysis for #{validated.ticker} failed: #{Protocol.bounded_reason(reason)}.",
           status: :failed,
           permission_decision: permission_decision,
           analysis_id: analysis_id,
           ticker: validated.ticker,
           analysis_date: Date.to_iso8601(validated.analysis_date),
           engine: validated.engine,
           error: Protocol.bounded_reason(reason),
           surface_nodes: surface_nodes,
           persistence_error: persistence_error,
           duration_ms: duration_ms,
           bridge_duration_ms: if(python_engine?(validated.engine), do: duration_ms, else: nil),
           objective_id: validated.objective_id,
           step_id: validated.step_id,
           actions: [
             Actions.action(
               "run_analysis",
               :failed,
               :stocksage_analyze,
               permission_decision,
               %{
                 analysis_id: analysis_id,
                 ticker: validated.ticker,
                 analysis_date: Date.to_iso8601(validated.analysis_date),
                 engine: validated.engine,
                 duration_ms: duration_ms,
                 bridge_duration_ms:
                   if(python_engine?(validated.engine), do: duration_ms, else: nil),
                 error: Protocol.bounded_reason(reason),
                 queue_entry_id: validated.queue_entry_id,
                 source_analysis_id: validated.source_analysis_id,
                 objective_id: validated.objective_id,
                 step_id: validated.step_id
               }
             )
           ]
         }}

      {:error, diagnostics} ->
        error(permission_decision, :surface_node_validation_failed, diagnostics)
    end
  end

  defp write_detail(analysis, validated, result, truncated?) do
    detail_attrs = %{
      analysis_id: analysis.id,
      user_id: validated.user_id,
      section: "result",
      agent: detail_agent(validated.engine),
      content: bounded(detail_content(result), min(persisted_detail_max(), @detail_content_max)),
      payload:
        %{
          "engine" => validated.engine,
          "truncated" => truncated?,
          "stub" => result_field(result, :stub, false),
          "native_report" =>
            if(validated.engine in ["native", "both"],
              do: native_report_payload(validated, result),
              else: nil
            ),
          "python_report" =>
            if(validated.engine == "both", do: result_field(result, :python_report), else: nil),
          "parity_diff" => result_field(result, :parity_diff)
        }
        |> drop_nil_values()
    }

    Analyses.create_detail(detail_attrs)
  end

  # The persisted detail body cap is unified with the in-flight bridge bound
  # via `stocksage.bridge_max_output_bytes` (v0.22 audit, gap 5). Operators
  # can lower this in Settings Central if they want tighter trace/redaction
  # posture; bridge_max_output_bytes governs the bridge response too, so the
  # two stay aligned.
  defp persisted_detail_max do
    case Settings.get("stocksage.bridge_max_output_bytes") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> @default_detail_max
    end
  rescue
    _exception -> @default_detail_max
  end

  defp result_field(result, key, default \\ nil)

  defp result_field(result, key, default) when is_map(result) and is_atom(key) do
    Map.get(result, key, Map.get(result, Atom.to_string(key), default))
  end

  defp result_field(_result, _key, default), do: default

  defp parity_diff_json(result) do
    case result_field(result, :parity_diff) do
      nil -> nil
      parity_diff -> Jason.encode!(json_safe(parity_diff))
    end
  end

  defp analysis_source("native"), do: "native"
  defp analysis_source("both"), do: "native_python_parity"
  defp analysis_source(_engine), do: "python_bridge"

  defp persisted_engine("tradingagents"), do: "tradingagents"
  defp persisted_engine(engine) when engine in ["native", "python", "both"], do: engine
  defp persisted_engine(_engine), do: "tradingagents"

  defp bridge_engine("python"), do: "tradingagents"
  defp bridge_engine(engine), do: engine

  defp detail_agent("native"), do: "native_coordinator"
  defp detail_agent("both"), do: "native_python_parity"
  defp detail_agent(_engine), do: "python_bridge"

  defp native_report_payload(%{engine: "both"}, result) do
    result
    |> result_field(:native_report)
    |> json_safe()
  end

  defp native_report_payload(_validated, result), do: redact_native_result(result)

  defp native_trace_metadata(%{engine: engine}, result) when engine in ["native", "both"] do
    report =
      case engine do
        "both" -> result_field(result, :native_report, %{})
        "native" -> result
      end

    %{
      agent_reports: native_trace_agent_reports(report),
      debate_rounds: native_trace_debate_rounds(report),
      parity_diff: result_field(result, :parity_diff),
      generation_modes: native_trace_generation_modes(report)
    }
    |> drop_nil_values()
    |> json_safe()
  end

  defp native_trace_metadata(_validated, _result), do: nil

  defp native_trace_agent_reports(report) when is_map(report) do
    report
    |> result_field(:agent_reports, %{})
    |> case do
      reports when is_map(reports) ->
        reports
        |> Enum.map(fn {agent_id, packet} ->
          %{
            agent_id: agent_id,
            role: result_field(packet, :role),
            status: result_field(packet, :status),
            summary: bounded(result_field(packet, :summary), 180),
            confidence: result_field(packet, :confidence),
            duration_ms: result_field(packet, :duration_ms),
            model_profile: result_field(packet, :model_profile),
            generation_mode: result_field(packet, :generation_mode)
          }
          |> drop_nil_values()
        end)
        |> Enum.sort_by(&Map.get(&1, :agent_id, ""))

      _other ->
        []
    end
  end

  defp native_trace_agent_reports(_report), do: []

  defp native_trace_debate_rounds(report) when is_map(report) do
    report
    |> result_field(:debate_rounds, [])
    |> List.wrap()
    |> Enum.map(fn round ->
      %{
        round_index: result_field(round, :round_index),
        bull_summary: round |> result_field(:bull, %{}) |> result_field(:summary),
        bear_summary: round |> result_field(:bear, %{}) |> result_field(:summary),
        risk_count: round |> result_field(:risks, []) |> List.wrap() |> length()
      }
      |> drop_nil_values()
    end)
  end

  defp native_trace_debate_rounds(_report), do: []

  defp native_trace_generation_modes(report) when is_map(report) do
    report
    |> native_trace_agent_reports()
    |> Enum.map(&Map.get(&1, :generation_mode))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp native_trace_generation_modes(_report), do: []

  defp detail_content(result) when is_map(result) do
    result_field(result, :raw) || Jason.encode!(json_safe(result))
  end

  defp redact_native_result(result) when is_map(result) do
    result
    |> Map.take([
      :engine,
      :ticker,
      :analysis_date,
      :agent_ids,
      :agent_reports,
      :debate_rounds,
      :final_trade_decision,
      :recommendation,
      :confidence,
      :investment_plan,
      :trader_investment_plan,
      :warnings,
      :native_report,
      :python_report,
      :parity_diff,
      :generated_at
    ])
    |> json_safe()
  end

  defp json_safe(value) do
    value
    |> AllbertSignals.redact()
    |> to_json_safe()
  end

  defp to_json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp to_json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp to_json_safe(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, json_key(key), to_json_safe(nested))
    end)
  end

  defp to_json_safe(value) when is_list(value), do: Enum.map(value, &to_json_safe/1)
  defp to_json_safe(value) when is_tuple(value), do: inspect(value)

  defp to_json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp to_json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp to_json_safe(nil), do: nil
  defp to_json_safe(value), do: inspect(value, limit: 20, printable_limit: 1_000)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)

  defp drop_nil_values(map) when is_map(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp update_queue(validated, analysis, status, started_at, reason \\ nil)

  defp update_queue(
         %{queue_entry_id: queue_id, user_id: user_id} = validated,
         analysis,
         status,
         started_at,
         _reason
       )
       when is_binary(queue_id) and queue_id != "" do
    with {:ok, entry} <- Queue.get_entry(user_id, queue_id) do
      _ =
        Queue.update_entry_status(entry, Atom.to_string(status), %{
          objective_id: Map.get(validated, :objective_id),
          step_id: Map.get(validated, :step_id)
        })

      Queue.create_run(entry, %{
        status: Atom.to_string(status),
        started_at: started_at,
        finished_at: DateTime.utc_now(),
        analysis_id: Map.get(analysis, :id)
      })
    end

    :ok
  end

  defp update_queue(_validated, _analysis, _status, _started_at, _reason), do: :ok

  defp normalize_ticker(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, :invalid_ticker}
      String.length(trimmed) > @max_ticker -> {:error, :invalid_ticker}
      Regex.match?(@ticker_pattern, trimmed) -> {:ok, String.upcase(trimmed)}
      true -> {:error, :invalid_ticker}
    end
  end

  defp normalize_ticker(_), do: {:error, :invalid_ticker}

  defp normalize_analysis_date(%Date{} = date), do: validate_date_range(date)

  defp normalize_analysis_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> validate_date_range(date)
      _other -> {:error, :invalid_analysis_date}
    end
  end

  defp normalize_analysis_date(_), do: {:error, :invalid_analysis_date}

  defp validate_date_range(date) do
    today = Date.utc_today()

    if Date.diff(date, today) <= @max_analysis_date_offset_days do
      {:ok, date}
    else
      {:error, :invalid_analysis_date}
    end
  end

  defp normalize_engine(params) when is_map(params) do
    cond do
      normalize_bool(Actions.field(params, :compare_python)) ->
        "both"

      true ->
        params
        |> Actions.field(:engine)
        |> normalize_engine_value()
    end
  end

  defp normalize_engine_value(nil), do: "native"
  defp normalize_engine_value(""), do: "native"

  defp normalize_engine_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "native" -> "native"
      "python" -> "python"
      "tradingagents" -> "tradingagents"
      "both" -> "both"
      other -> other
    end
  end

  defp normalize_engine_value(_), do: "native"

  defp normalize_evidence_mode(value) when value in ["live", "fixture", "compare"], do: value
  defp normalize_evidence_mode(_value), do: nil

  defp normalize_bool(true), do: true
  defp normalize_bool("true"), do: true
  defp normalize_bool(1), do: true
  defp normalize_bool(_other), do: false

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value) when is_binary(value), do: String.trim(value)
  defp blank(_), do: nil

  defp bridge_disabled(validated, permission_decision) do
    {:ok,
     %{
       message: "StockSage Python bridge is disabled; analysis cannot run.",
       status: :error,
       error: :bridge_disabled,
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{
             error: :bridge_disabled,
             ticker: validated.ticker,
             engine: validated.engine
           }
         )
       ]
     }}
  end

  defp native_disabled(validated, permission_decision) do
    {:ok,
     %{
       message: "StockSage native engine is disabled; analysis cannot run.",
       status: :error,
       error: :native_engine_disabled,
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{
             error: :native_engine_disabled,
             ticker: validated.ticker,
             engine: validated.engine
           }
         )
       ]
     }}
  end

  defp python_comparison_disabled(validated, permission_decision) do
    {:ok,
     %{
       message:
         "StockSage Python comparison is disabled; explicit Python/parity analysis cannot run.",
       status: :error,
       error: :python_comparison_disabled,
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{
             error: :python_comparison_disabled,
             ticker: validated.ticker,
             engine: validated.engine
           }
         )
       ]
     }}
  end

  defp target_execution_mode("native"), do: :native_agent_graph
  defp target_execution_mode("both"), do: :native_python_parity
  defp target_execution_mode(_engine), do: :python_bridge

  defp confirmation_disclosure(%{engine: "native"} = validated) do
    evidence =
      case validated.evidence_mode do
        "fixture" -> "fixture evidence; no market-data network calls from evidence actions"
        "compare" -> "fixture plus live evidence comparison where Resource Access grants allow it"
        _other -> "live evidence actions where Resource Access grants allow them"
      end

    "Native StockSage specialist analysis: supervised Jido agents will run with #{evidence}. " <>
      "Specialist output is advisory and cannot authorize trades."
  end

  defp confirmation_disclosure(%{engine: "both"} = validated) do
    confirmation_disclosure(%{validated | engine: "native"}) <>
      " Python comparison is explicitly requested and will run only through the documented bridge."
  end

  defp confirmation_disclosure(validated) do
    if validated.force_stub do
      "Stub-mode Python analysis: no TradingAgents call will be made. " <>
        "Persisted detail row will be labeled stub: true."
    else
      "Explicit Python TradingAgents analysis will make external market-data API calls as configured."
    end
  end

  defp native_engine?(engine), do: engine in ["native", "both"]
  defp python_engine?(engine), do: engine in ["python", "tradingagents", "both"]

  defp invalid(permission_decision, error, message) do
    {:ok,
     %{
       message: message,
       status: :error,
       error: error,
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{error: error}
         )
       ]
     }}
  end

  defp denied(_validated, permission_decision) do
    {:ok,
     %{
       message:
         "StockSage analysis is not permitted: #{Map.get(permission_decision, :reason, "denied by policy")}.",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           PermissionGate.response_status(permission_decision),
           :stocksage_analyze,
           permission_decision,
           %{error: :permission_denied}
         )
       ]
     }}
  end

  defp error(permission_decision, error, detail) do
    {:ok,
     %{
       message: "Unable to run StockSage analysis: #{inspect(error)}",
       status: :error,
       error: error,
       detail: detail,
       permission_decision: permission_decision,
       actions: [
         Actions.action(
           "run_analysis",
           :error,
           :stocksage_analyze,
           permission_decision,
           %{error: error}
         )
       ]
     }}
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_other), do: false

  defp confirmation_id(%{confirmation: %{id: id}}) when is_binary(id), do: id
  defp confirmation_id(%{"confirmation" => %{"id" => id}}) when is_binary(id), do: id
  defp confirmation_id(_other), do: nil

  defp origin(context, validated) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor, validated.user_id),
      user_id: validated.user_id,
      thread_id: validated.thread_id || Map.get(context, :thread_id),
      session_id: validated.session_id || Map.get(context, :session_id),
      surface: Map.get(context, :surface, "action"),
      app_id: :stocksage,
      objective_id: validated.objective_id,
      step_id: validated.step_id
    }
  end

  defp bounded(nil, _max), do: nil

  defp bounded(value, max) when is_binary(value) do
    if byte_size(value) > max, do: binary_part(value, 0, max), else: value
  end

  defp bounded(value, max), do: value |> inspect() |> bounded(max)

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp errors_on(other), do: inspect(other)

  defp bridge_enabled? do
    case Settings.get("stocksage.bridge_enabled") do
      {:ok, value} when is_boolean(value) -> value
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp native_engine_enabled? do
    case Settings.get("stocksage.native_engine_enabled") do
      {:ok, value} when is_boolean(value) -> value
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp python_comparison_enabled? do
    case Settings.get("stocksage.python_comparison_enabled") do
      {:ok, value} when is_boolean(value) -> value
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp requested_payload(validated, context) do
    %{
      ticker: validated.ticker,
      analysis_date: Date.to_iso8601(validated.analysis_date),
      engine: validated.engine,
      user_id: validated.user_id,
      thread_id: validated.thread_id || Actions.field(context, :thread_id),
      session_id: validated.session_id || Actions.field(context, :session_id),
      queue_entry_id: validated.queue_entry_id,
      source_analysis_id: validated.source_analysis_id,
      objective_id: validated.objective_id,
      step_id: validated.step_id,
      confirmation_id: confirmation_id(context),
      input_signal_id: Actions.field(context, :input_signal_id),
      trace_id: Actions.field(context, :trace_id)
    }
  end

  defp emit_analysis_signal(type, payload) when is_binary(type) and is_map(payload) do
    case Signal.new(
           type,
           AllbertSignals.redact(payload),
           source: "/allbert/stocksage/run_analysis",
           subject: Map.get(payload, :user_id)
         ) do
      {:ok, %Signal{} = signal} ->
        AllbertSignals.log(signal)
        WorkspaceEmitters.stocksage_signal(type, payload)

      _other ->
        :ok
    end
  rescue
    _exception -> :ok
  end
end
