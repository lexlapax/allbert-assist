defmodule StockSage.Actions.RunAnalysis do
  @moduledoc """
  StockSage analysis execution through the supervised Python bridge.

  On first call the action creates a durable confirmation record and returns
  `:needs_confirmation`. On the approved resume path (`approve_confirmation`
  invokes this action with `confirmation.approved? = true`), the action
  re-checks Security Central, calls `StockSage.TraderBridge.analyze/1`, and
  persists the result rows. Failures write a failure row; bridge crashes,
  timeouts, and disabled-bridge cases are surfaced as structured errors.

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
    description: "Run a StockSage analysis for a ticker through the Python bridge.",
    category: "stocksage",
    tags: ["stocksage", "analysis", "confirmation"],
    schema: [
      ticker: [type: :string, required: true],
      analysis_date: [type: :string, required: true],
      engine: [type: :string, required: false],
      user_id: [type: :string, required: false],
      queue_entry_id: [type: :string, required: false],
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
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals, as: AllbertSignals
  alias Jido.Signal
  alias StockSage.Actions
  alias StockSage.Analyses
  alias StockSage.Bridge.Protocol
  alias StockSage.Queue
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
  @signal_analysis_requested "allbert.stocksage.analysis_requested"
  @signal_analysis_completed "allbert.stocksage.analysis_completed"
  @signal_analysis_failed "allbert.stocksage.analysis_failed"

  def capability do
    Actions.capability(:stocksage_analyze, %{
      confirmation: :required,
      exposure: :agent,
      execution_mode: :python_bridge,
      risk_tier: :high,
      resumable?: true
    })
  end

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:stocksage_analyze, context)

    with {:ok, ticker} <- normalize_ticker(Actions.field(params, :ticker)),
         {:ok, analysis_date} <- normalize_analysis_date(Actions.field(params, :analysis_date)),
         engine <- normalize_engine(Actions.field(params, :engine)),
         {:ok, user_id} <- Actions.user_id(params, context) do
      validated = %{
        ticker: ticker,
        analysis_date: analysis_date,
        engine: engine,
        user_id: user_id,
        queue_entry_id: blank(Actions.field(params, :queue_entry_id)),
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
      not bridge_enabled?() ->
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
           target_action: %{name: "run_analysis", module: inspect(__MODULE__)},
           target_permission: :stocksage_analyze,
           target_execution_mode: :python_bridge,
           security_decision: permission_decision,
           params_summary: %{
             ticker: validated.ticker,
             analysis_date: Date.to_iso8601(validated.analysis_date),
             engine: validated.engine,
             user_id: validated.user_id,
             queue_entry_id: validated.queue_entry_id,
             force_stub: validated.force_stub,
             disclosure:
               if(validated.force_stub,
                 do:
                   "Stub-mode analysis: no TradingAgents call will be made. " <>
                     "Persisted detail row will be labeled stub: true.",
                 else:
                   "TradingAgents will make external market-data API calls as part of this analysis."
               )
           },
           resume_params_ref: %{
             ticker: validated.ticker,
             analysis_date: Date.to_iso8601(validated.analysis_date),
             engine: validated.engine,
             user_id: validated.user_id,
             queue_entry_id: validated.queue_entry_id,
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
                 user_id: validated.user_id,
                 queue_entry_id: validated.queue_entry_id,
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

      analyze_params =
        %{
          ticker: validated.ticker,
          analysis_date: Date.to_iso8601(validated.analysis_date),
          engine: validated.engine
        }
        |> maybe_put(:force_stub, validated.force_stub)

      case TraderBridge.analyze(analyze_params) do
        {:ok, result} ->
          persist_success(validated, result, context, permission_decision, started_at)

        {:error, reason} ->
          persist_failure(validated, reason, context, permission_decision, started_at)
      end
    else
      {:error, queue_reason} ->
        queue_entry_invalid(validated, permission_decision, queue_reason)
    end
  end

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
      user_id: validated.user_id,
      queue_entry_id: validated.queue_entry_id,
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
    summary = bounded(Map.get(result, "summary"), @summary_max)
    truncated? = Map.get(result, "truncated", false)

    analysis_attrs = %{
      user_id: validated.user_id,
      symbol: validated.ticker,
      analysis_date: validated.analysis_date,
      status: "completed",
      source: "python_bridge",
      summary: summary,
      thread_id: Actions.field(context, :thread_id),
      session_id: Actions.field(context, :session_id),
      input_signal_id: Actions.field(context, :input_signal_id),
      trace_id: Actions.field(context, :trace_id),
      request_id: confirmation_id(context),
      metadata: %{
        "engine" => validated.engine,
        "bridge_duration_ms" => duration_ms,
        "truncated" => truncated?,
        "queue_entry_id" => validated.queue_entry_id
      }
    }

    # v0.22 audit closeout (Gap 1 — stub-mode visibility): surface the
    # `stub` flag in the action's response, runner metadata, completed
    # signal, and trace section so operators inspecting any of those
    # surfaces immediately see whether a row came from a real
    # TradingAgents propagate call or from the deterministic stub.
    stub? = Map.get(result, "stub", false)

    case Analyses.create_analysis(analysis_attrs) do
      {:ok, analysis} ->
        write_detail(analysis, validated, result, truncated?)
        update_queue(validated, analysis, :completed, started_at)

        emit_analysis_signal(@signal_analysis_completed, %{
          analysis_id: analysis.id,
          ticker: validated.ticker,
          analysis_date: Date.to_iso8601(validated.analysis_date),
          engine: validated.engine,
          user_id: validated.user_id,
          queue_entry_id: validated.queue_entry_id,
          bridge_duration_ms: duration_ms,
          truncated: truncated?,
          stub: stub?
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
           truncated: truncated?,
           stub: stub?,
           bridge_duration_ms: duration_ms,
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
                 bridge_duration_ms: duration_ms,
                 truncated: truncated?,
                 stub: stub?,
                 queue_entry_id: validated.queue_entry_id,
                 summary: summary
               }
             )
           ]
         }}

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
      source: "python_bridge",
      summary: summary,
      thread_id: Actions.field(context, :thread_id),
      session_id: Actions.field(context, :session_id),
      input_signal_id: Actions.field(context, :input_signal_id),
      trace_id: Actions.field(context, :trace_id),
      request_id: confirmation_id(context),
      metadata: %{
        "engine" => validated.engine,
        "bridge_duration_ms" => duration_ms,
        "error" => Protocol.bounded_reason(reason),
        "queue_entry_id" => validated.queue_entry_id
      }
    }

    {analysis_id, persistence_error} =
      case Analyses.create_analysis(analysis_attrs) do
        {:ok, analysis} -> {analysis.id, nil}
        {:error, changeset} -> {nil, errors_on(changeset)}
      end

    update_queue(validated, %{id: analysis_id}, :failed, started_at, reason)

    emit_analysis_signal(@signal_analysis_failed, %{
      analysis_id: analysis_id,
      ticker: validated.ticker,
      analysis_date: Date.to_iso8601(validated.analysis_date),
      engine: validated.engine,
      user_id: validated.user_id,
      queue_entry_id: validated.queue_entry_id,
      bridge_duration_ms: duration_ms,
      error: Protocol.bounded_reason(reason)
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
       error: reason,
       persistence_error: persistence_error,
       bridge_duration_ms: duration_ms,
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
             bridge_duration_ms: duration_ms,
             error: Protocol.bounded_reason(reason),
             queue_entry_id: validated.queue_entry_id
           }
         )
       ]
     }}
  end

  defp write_detail(analysis, validated, result, truncated?) do
    detail_attrs = %{
      analysis_id: analysis.id,
      user_id: validated.user_id,
      section: "result",
      agent: "python_bridge",
      content: bounded(Map.get(result, "raw"), persisted_detail_max()),
      payload: %{
        "engine" => validated.engine,
        "truncated" => truncated?,
        "stub" => Map.get(result, "stub", false)
      }
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

  defp update_queue(validated, analysis, status, started_at, reason \\ nil)

  defp update_queue(
         %{queue_entry_id: queue_id, user_id: user_id},
         analysis,
         status,
         started_at,
         _reason
       )
       when is_binary(queue_id) and queue_id != "" do
    with {:ok, entry} <- Queue.get_entry(user_id, queue_id) do
      _ = Queue.update_entry_status(entry, Atom.to_string(status))

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

  defp normalize_engine(nil), do: "tradingagents"
  defp normalize_engine(""), do: "tradingagents"
  defp normalize_engine(value) when is_binary(value), do: String.trim(value)
  defp normalize_engine(_), do: "tradingagents"

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
      session_id: Map.get(context, :session_id),
      surface: Map.get(context, :surface, "action"),
      app_id: :stocksage
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

  defp requested_payload(validated, context) do
    %{
      ticker: validated.ticker,
      analysis_date: Date.to_iso8601(validated.analysis_date),
      engine: validated.engine,
      user_id: validated.user_id,
      queue_entry_id: validated.queue_entry_id,
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
      {:ok, %Signal{} = signal} -> AllbertSignals.log(signal)
      _other -> :ok
    end
  rescue
    _exception -> :ok
  end
end
