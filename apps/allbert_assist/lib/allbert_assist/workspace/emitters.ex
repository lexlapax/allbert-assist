defmodule AllbertAssist.Workspace.Emitters do
  @moduledoc """
  Best-effort workspace fragment emitters for durable runtime events.

  This module does not own persistence. It turns already-authoritative
  confirmation, objective, and app-analysis events into signed catalog-bound
  fragments that the workspace shell may render.
  """

  require Logger

  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Events
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @confirmation_emitter "AllbertAssist.Confirmations"
  @intent_emitter "AllbertAssist.Agents.IntentAgent"
  @objective_emitter "AllbertAssist.Objectives"
  @stocksage_emitter "StockSage.Actions.RunAnalysis"
  # The registered research delegate agent id — an allowed objective-agent
  # emitter (Guard.objective_agent_emitter?).
  @research_emitter "research.specialist"

  @analysis_requested "allbert.stocksage.analysis_requested"
  @analysis_completed "allbert.stocksage.analysis_completed"
  @analysis_failed "allbert.stocksage.analysis_failed"

  @spec confirmation_requested(map()) :: :ok
  def confirmation_requested(record) when is_map(record) do
    safe_emit(fn ->
      with {:ok, context} <- confirmation_context(record),
           id when is_binary(id) <- string_value(record, "id") do
        emit_fragment(%{
          id: "confirmation_#{safe_id(id)}",
          surface: confirmation_surface(record),
          emitter_id: @confirmation_emitter,
          user_id: context.user_id,
          thread_id: context.thread_id,
          scope: :ephemeral,
          kind: :approval_card,
          emitted_at: DateTime.utc_now(),
          metadata:
            bounded_map(%{
              confirmation_id: id,
              target_action: target_action_name(record),
              target_permission: string_value(record, "target_permission"),
              status: string_value(record, "status")
            })
        })
      end
    end)
  end

  def confirmation_requested(_record), do: :ok

  @spec intent_proposal(Handoff.t() | map(), map()) :: :ok
  def intent_proposal(handoff, context) when is_map(context) do
    safe_emit(fn ->
      canvas_destination = string_value(context, :canvas_destination)

      with {:ok, %Handoff{} = handoff} <- normalize_handoff(handoff),
           {:ok, context} <-
             context(string_value(context, :user_id), string_value(context, :thread_id)) do
        handoff = scope_intent_handoff(handoff, context.thread_id)
        same_app? = same_app_destination?(handoff, canvas_destination)

        emit_fragment(%{
          id: handoff.surface_id,
          surface: intent_surface(handoff, same_app?),
          emitter_id: @intent_emitter,
          user_id: context.user_id,
          thread_id: context.thread_id,
          scope: :ephemeral,
          kind: :approval_card,
          emitted_at: DateTime.utc_now(),
          metadata:
            bounded_map(%{
              source: "intent_handoff",
              kind: handoff.kind,
              app_id: handoff.app_id,
              action_name: handoff.action_name,
              source_surface_id: base_intent_surface_id(handoff.surface_id)
            })
        })
      end
    end)
  end

  def intent_proposal(_handoff, _context), do: :ok

  @spec confirmation_resolved(map()) :: :ok
  def confirmation_resolved(record) when is_map(record) do
    safe_emit(fn ->
      with {:ok, context} <- confirmation_context(record),
           id when is_binary(id) <- string_value(record, "id") do
        Events.ephemeral_closed(
          "confirmation_#{safe_id(id)}",
          context.user_id,
          context.thread_id,
          :confirmation_resolved,
          %{
            confirmation_id: id,
            status: string_value(record, "status")
          }
        )
      end
    end)
  end

  def confirmation_resolved(_record), do: :ok

  @spec objective_lifecycle(atom(), struct(), map()) :: :ok
  def objective_lifecycle(kind, objective, metadata \\ %{})

  def objective_lifecycle(kind, objective, metadata) when is_atom(kind) and is_map(metadata) do
    safe_emit(fn ->
      with {:ok, context} <- objective_context(objective),
           id when is_binary(id) <- Map.get(objective, :id) do
        emit_fragment(%{
          id: "objective_#{safe_id(id)}",
          surface: objective_surface(kind, objective, metadata),
          emitter_id: @objective_emitter,
          user_id: context.user_id,
          thread_id: context.thread_id,
          scope: :canvas,
          kind: :objective_card,
          emitted_at: DateTime.utc_now(),
          metadata:
            bounded_map(%{
              objective_id: id,
              stage: string_value(metadata, :stage),
              status: Map.get(objective, :status),
              active_app: Map.get(objective, :active_app),
              lifecycle_kind: Atom.to_string(kind)
            })
        })
      end
    end)
  end

  def objective_lifecycle(_kind, _objective, _metadata), do: :ok

  @spec stocksage_signal(String.t(), map()) :: :ok
  def stocksage_signal(type, payload) when is_binary(type) and is_map(payload) do
    safe_emit(fn -> emit_stocksage_fragments(type, payload) end)
  end

  def stocksage_signal(_type, _payload), do: :ok

  @doc """
  Emit the research-result canvas card for a completed research delegate run
  (v1.0.1 M4.2.4). Delivery of an already-authorized result — best-effort,
  non-authoritative; skipped without workspace context (user_id + thread_id).
  """
  def research_result(payload) when is_map(payload) do
    safe_emit(fn -> emit_research_fragment(payload) end)
  end

  def research_result(_payload), do: :ok

  defp emit_research_fragment(payload) do
    with {:ok, context} <- payload_context(payload) do
      payload = Redactor.redact(payload)
      id = string_value(payload, :objective_id) || "research"
      summary = string_value(payload, :summary) || "Browser research completed."
      # Workspace surface props must not carry remote URLs (unsafe_prop_value
      # guard) — the tile names the source HOST; the full URL is delivered in
      # the thread message and the objective record.
      source_host = payload |> research_source() |> url_host()

      body =
        case source_host do
          nil -> truncate(summary, 500)
          host -> truncate("#{truncate(summary, 400)} Source: #{host}", 500)
        end

      emit_fragment(%{
        id: "research_result_#{safe_id(id)}",
        surface:
          surface(
            :workspace_objective_card,
            :allbert,
            "Browser Research",
            "/workspace",
            :workspace,
            body,
            [
              node("research-result-#{safe_id(id)}", :analysis_card, %{
                title: "Browser research completed",
                body: body,
                status: "completed",
                objective_id: string_value(payload, :objective_id),
                source: source_host
              })
            ],
            %{source: "allbert_research", fragment_id: "research_result_#{safe_id(id)}"}
          ),
        emitter_id: @research_emitter,
        user_id: context.user_id,
        thread_id: context.thread_id,
        scope: :canvas,
        kind: :analysis_card,
        emitted_at: DateTime.utc_now(),
        metadata: %{
          source: "allbert_research",
          objective_id: string_value(payload, :objective_id)
        }
      })
    end
  end

  defp url_host(nil), do: nil

  defp url_host(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  # Surface fallback_text is capped at 512; keep the tile body inside it.
  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max - 1) <> "…"
  end

  defp truncate(value, _max), do: value

  # Research sources arrive as maps (%{url:, title:, ...}) from the delegate —
  # extract a printable URL/string; never interpolate a map.
  defp research_source(payload) do
    payload
    |> map_value(:sources)
    |> List.wrap()
    |> List.first()
    |> case do
      %{} = entry -> string_value(entry, :url) || string_value(entry, :title)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp emit_stocksage_fragments(type, payload) do
    with {:ok, context} <- payload_context(payload) do
      payload = Redactor.redact(payload)

      type
      |> stocksage_fragment_specs(payload)
      |> Enum.each(&emit_stocksage_fragment(&1, type, context))
    end
  end

  defp emit_stocksage_fragment(spec, type, context) do
    emit_fragment(%{
      id: spec.id,
      surface: stocksage_surface(spec),
      emitter_id: @stocksage_emitter,
      user_id: context.user_id,
      thread_id: context.thread_id,
      scope: :canvas,
      kind: spec.kind,
      emitted_at: DateTime.utc_now(),
      metadata: Map.put(spec.metadata, :signal_type, type)
    })
  end

  defp confirmation_surface(record) do
    id = string_value(record, "id")
    action = target_action_name(record) || "runtime action"
    permission = string_value(record, "target_permission") || "permission"
    body = "Approval is required before #{action} can continue."

    surface(
      :workspace_confirmation_approval,
      :allbert,
      "Approval Required",
      "/workspace",
      :workspace,
      body,
      [
        node("confirmation-#{safe_id(id)}", :approval_card, %{
          title: "Approval required",
          body: body,
          status: string_value(record, "status") || "pending",
          confirmation_id: id,
          target_action: action,
          target_permission: permission,
          requested_at: string_value(record, "requested_at"),
          expires_at: string_value(record, "expires_at")
        })
      ],
      %{source: "confirmations", confirmation_id: id}
    )
  end

  defp intent_surface(%Handoff{} = handoff, same_app?) do
    handoff_map = Handoff.to_map(handoff)
    body = intent_body(handoff, same_app?)

    surface(
      :workspace_intent_handoff,
      :allbert,
      intent_surface_title(handoff),
      "/workspace",
      :workspace,
      body,
      intent_nodes(handoff, handoff_map, body),
      %{source: "intent_handoff", handoff: handoff_map}
    )
  end

  defp intent_body(%Handoff{kind: :app_handoff} = handoff, true) do
    label = handoff.label || "Run #{app_label(handoff.app_id)}"
    slot_summary = inline_slot_summary(handoff.extracted_slots)
    "#{label}#{slot_summary}? Accept to continue."
  end

  defp intent_body(%Handoff{} = handoff, _same_app?), do: Handoff.message(handoff)

  defp same_app_destination?(%Handoff{app_id: app_id}, "app:" <> app_destination) do
    Atom.to_string(app_id) == app_destination
  end

  defp same_app_destination?(_handoff, _canvas_destination), do: false

  defp inline_slot_summary(slots) when is_map(slots) do
    Enum.find_value([:ticker, "ticker", :symbol, "symbol"], "", fn key ->
      case Map.get(slots, key) do
        value when is_binary(value) and value != "" -> " for #{value}"
        _value -> nil
      end
    end)
  end

  defp inline_slot_summary(_slots), do: ""

  defp intent_nodes(%Handoff{kind: :app_handoff} = handoff, handoff_map, body) do
    [
      node("intent-handoff", :approval_card, %{
        dom_id: "intent-handoff",
        title: "Open #{handoff_target_label(handoff)}?",
        body: body,
        status: "handoff",
        external_id: handoff.surface_id
      }),
      node("intent-handoff-accept", :action_button, intent_button_props(handoff_map, "Accept")),
      node(
        "intent-handoff-decline",
        :button,
        intent_button_props(handoff_map, "Decline")
        |> Map.put(:dom_id, "intent-handoff-decline")
        |> Map.put(:phx_click, "decline_intent_handoff")
      )
    ]
  end

  defp intent_nodes(%Handoff{kind: :clarify_intent} = handoff, handoff_map, body) do
    [
      node("intent-clarification", :approval_card, %{
        dom_id: "intent-clarification",
        title: "Clarify #{app_label(handoff.app_id)}",
        body: body,
        status: "clarify",
        external_id: handoff.surface_id
      })
      | intent_option_nodes(handoff_map)
    ]
  end

  defp intent_option_nodes(%{options: options} = handoff_map) when is_list(options) do
    options
    |> Enum.with_index(1)
    |> Enum.map(fn {option, index} ->
      node("intent-option-#{index}", :button, %{
        title: string_value(option, :label) || "Option #{index}",
        dom_id: "intent-option-#{index}",
        phx_click: "select_intent_option",
        surface_id: string_value(handoff_map, :surface_id),
        app_id: string_value(option, :app_id),
        action_name: string_value(option, :action_name),
        destination: string_value(option, :destination),
        source_text: string_value(handoff_map, :source_text),
        intent_option?: true
      })
    end)
  end

  defp intent_option_nodes(_handoff_map), do: []

  defp intent_button_props(handoff_map, title) do
    %{
      title: title,
      dom_id: "intent-handoff-accept",
      phx_click: "accept_intent_handoff",
      surface_id: string_value(handoff_map, :surface_id),
      app_id: string_value(handoff_map, :app_id),
      action_name: string_value(handoff_map, :action_name),
      destination: string_value(handoff_map, :destination),
      source_text: string_value(handoff_map, :source_text),
      ticker: string_value(handoff_map[:extracted_slots] || %{}, :ticker)
    }
  end

  defp handoff_target_label(%Handoff{destination: "workspace:calendar"}), do: "Calendar"
  defp handoff_target_label(%Handoff{destination: "workspace:mail"}), do: "Mail"
  defp handoff_target_label(%Handoff{destination: "workspace:github"}), do: "GitHub"
  defp handoff_target_label(%Handoff{destination: "workspace:discover"}), do: "Discovery"
  defp handoff_target_label(%Handoff{app_id: app_id}), do: app_label(app_id)

  defp intent_surface_title(%Handoff{kind: :app_handoff}), do: "App Handoff"
  defp intent_surface_title(%Handoff{kind: :clarify_intent}), do: "Clarification"

  defp scope_intent_handoff(%Handoff{} = handoff, thread_id) do
    %{handoff | surface_id: scoped_intent_surface_id(handoff.surface_id, thread_id)}
  end

  defp scoped_intent_surface_id(surface_id, thread_id) do
    digest =
      :crypto.hash(:sha256, to_string(thread_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "#{surface_id}_#{digest}"
  end

  defp base_intent_surface_id(surface_id) when is_binary(surface_id) do
    Regex.replace(~r/_[a-f0-9]{12}$/, surface_id, "")
  end

  defp objective_surface(kind, objective, metadata) do
    objective_id = Map.get(objective, :id)
    title = Map.get(objective, :title) || "Objective"
    stage = string_value(metadata, :stage) || Atom.to_string(kind)
    status = Map.get(objective, :status) || "open"
    body = objective_body(kind, objective, metadata)

    surface(
      :workspace_objective_card,
      :allbert,
      "Objective Progress",
      "/workspace",
      :workspace,
      body,
      [
        node("objective-#{safe_id(objective_id)}", :objective_card, %{
          title: title,
          body: body,
          status: status,
          objective_id: objective_id,
          stage: stage,
          lifecycle_kind: Atom.to_string(kind)
        })
      ],
      %{source: "objectives", objective_id: objective_id, lifecycle_kind: Atom.to_string(kind)}
    )
  end

  defp objective_body(:completed, _objective, metadata) do
    string_value(metadata, :completion_summary) || string_value(metadata, :observation_summary) ||
      "Objective completed."
  end

  defp objective_body(:impasse, _objective, metadata) do
    string_value(metadata, :reason) || string_value(metadata, :observation_summary) ||
      "Objective needs operator attention."
  end

  defp objective_body(:observed, objective, metadata) do
    string_value(metadata, :observation_summary) || Map.get(objective, :last_observation_summary) ||
      Map.get(objective, :progress_summary) || "Observation recorded."
  end

  defp objective_body(_kind, objective, metadata) do
    string_value(metadata, :summary) || Map.get(objective, :progress_summary) ||
      Map.get(objective, :objective) || "Objective progress updated."
  end

  defp stocksage_fragment_specs(@analysis_requested, payload) do
    base_payload = stocksage_payload(payload)

    id =
      base_payload.confirmation_id || base_payload.objective_id || base_payload.ticker ||
        "requested"

    [
      stock_spec(:analysis_card, "stocksage_analysis_request_#{safe_id(id)}", %{
        title: "#{base_payload.ticker || "StockSage"} analysis requested",
        body: "Analysis is approved and queued for execution.",
        status: "requested",
        payload: base_payload
      })
    ]
  end

  defp stocksage_fragment_specs(@analysis_completed, payload) do
    base_payload = stocksage_payload(payload)
    analysis_id = base_payload.analysis_id || base_payload.ticker || "completed"
    native_trace = map_value(payload, :native_trace) || %{}

    [
      stock_spec(:analysis_card, "stocksage_analysis_#{safe_id(analysis_id)}", %{
        title: "#{base_payload.ticker || "StockSage"} analysis completed",
        body: string_value(payload, :summary) || "StockSage analysis completed.",
        status: "completed",
        payload: base_payload
      })
      | native_trace_specs(analysis_id, native_trace)
    ]
  end

  defp stocksage_fragment_specs(@analysis_failed, payload) do
    base_payload = stocksage_payload(payload)
    id = base_payload.analysis_id || base_payload.objective_id || base_payload.ticker || "failed"

    [
      stock_spec(:analysis_card, "stocksage_analysis_failed_#{safe_id(id)}", %{
        title: "#{base_payload.ticker || "StockSage"} analysis failed",
        body: string_value(payload, :error) || "StockSage analysis failed.",
        status: "failed",
        payload: base_payload
      })
    ]
  end

  defp stocksage_fragment_specs(_type, _payload), do: []

  defp native_trace_specs(_analysis_id, trace) when trace == %{}, do: []

  defp native_trace_specs(analysis_id, trace) do
    [
      agent_report_spec(analysis_id, trace),
      debate_round_spec(analysis_id, trace),
      parity_spec(analysis_id, trace)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp agent_report_spec(analysis_id, trace) do
    reports = trace |> map_value(:agent_reports) |> List.wrap()

    if reports == [] do
      nil
    else
      stock_spec(:agent_report_card, "stocksage_agent_reports_#{safe_id(analysis_id)}", %{
        title: "Specialist reports",
        body: "#{length(reports)} specialist report(s) recorded.",
        status: "completed",
        payload: %{analysis_id: analysis_id, report_count: length(reports), reports: reports}
      })
    end
  end

  defp debate_round_spec(analysis_id, trace) do
    rounds = trace |> map_value(:debate_rounds) |> List.wrap()

    if rounds == [] do
      nil
    else
      stock_spec(:debate_round_card, "stocksage_debate_rounds_#{safe_id(analysis_id)}", %{
        title: "Debate rounds",
        body: "#{length(rounds)} debate round(s) recorded.",
        status: "completed",
        payload: %{analysis_id: analysis_id, round_count: length(rounds), rounds: rounds}
      })
    end
  end

  defp parity_spec(analysis_id, trace) do
    case map_value(trace, :parity_diff) do
      nil ->
        nil

      parity_diff ->
        stock_spec(:parity_card, "stocksage_parity_#{safe_id(analysis_id)}", %{
          title: "Parity comparison",
          body: "Native/Python parity metadata recorded.",
          status: "completed",
          payload: %{analysis_id: analysis_id, parity_diff: parity_diff}
        })
    end
  end

  defp stocksage_surface(%{kind: kind} = spec) do
    surface(
      stocksage_surface_id(kind),
      :stocksage,
      "StockSage Analysis",
      "/workspace",
      :analysis,
      spec.props.body,
      [
        node("stocksage-#{kind}-#{safe_id(spec.id)}", kind, spec.props)
      ],
      %{source: "stocksage", fragment_id: spec.id}
    )
  end

  defp stock_spec(kind, id, %{payload: payload} = props) do
    props =
      props
      |> Map.put(:payload, bounded_map(payload))
      |> Map.put_new(:analysis_id, Map.get(payload, :analysis_id))
      |> Map.put_new(:ticker, Map.get(payload, :ticker))
      |> Map.put_new(:analysis_date, Map.get(payload, :analysis_date))
      |> Map.put_new(:engine, Map.get(payload, :engine))
      |> Map.put_new(:route, analysis_route(Map.get(payload, :analysis_id)))
      |> drop_nil_values()

    %{
      id: id,
      kind: kind,
      props: props,
      metadata: bounded_map(payload)
    }
  end

  defp stocksage_payload(payload) do
    %{
      analysis_id: string_value(payload, :analysis_id),
      ticker: string_value(payload, :ticker),
      analysis_date: string_value(payload, :analysis_date),
      engine: string_value(payload, :engine),
      queue_entry_id: string_value(payload, :queue_entry_id),
      objective_id: string_value(payload, :objective_id),
      step_id: string_value(payload, :step_id),
      confirmation_id: string_value(payload, :confirmation_id),
      duration_ms: map_value(payload, :duration_ms),
      bridge_duration_ms: map_value(payload, :bridge_duration_ms),
      truncated: map_value(payload, :truncated),
      stub: map_value(payload, :stub)
    }
    |> drop_nil_values()
  end

  defp surface(id, app_id, label, path, kind, fallback_text, nodes, metadata) do
    %Surface{
      id: id,
      app_id: app_id,
      label: label,
      path: path,
      kind: kind,
      status: :available,
      fallback_text: fallback_text,
      nodes: nodes,
      metadata: bounded_map(metadata)
    }
  end

  defp node(id, component, props) do
    %Node{
      id: id |> to_string() |> String.slice(0, 64),
      component: component,
      props: bounded_map(props)
    }
  end

  defp emit_fragment(attrs) do
    with secret <- SigningSecret.ensure!(),
         {:ok, envelope} <- Envelope.sign(attrs, secret),
         :ok <- Fragment.emit(envelope) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("workspace runtime fragment skipped reason=#{inspect(reason)}")
        :ok
    end
  end

  defp safe_emit(fun) when is_function(fun, 0) do
    _ = fun.()
    :ok
  rescue
    exception ->
      Logger.debug("workspace runtime fragment failed reason=#{Exception.message(exception)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("workspace runtime fragment unavailable reason=#{inspect(reason)}")
      :ok
  end

  defp confirmation_context(record) do
    origin = map_value(record, "origin") || %{}
    user_id = string_value(origin, "user_id")
    thread_id = string_value(origin, "thread_id")
    context(user_id, thread_id)
  end

  defp objective_context(objective) do
    context(Map.get(objective, :user_id), Map.get(objective, :source_thread_id))
  end

  defp normalize_handoff(%Handoff{} = handoff), do: {:ok, handoff}
  defp normalize_handoff(%{} = attrs), do: Handoff.new(attrs)

  defp payload_context(payload) do
    context(string_value(payload, :user_id), string_value(payload, :thread_id))
  end

  defp context(user_id, thread_id)
       when is_binary(user_id) and user_id != "" and is_binary(thread_id) and thread_id != "" do
    {:ok, %{user_id: user_id, thread_id: thread_id}}
  end

  defp context(_user_id, _thread_id), do: {:error, :missing_workspace_context}

  defp app_label(:stocksage), do: "StockSage"

  defp app_label(app_id) when is_atom(app_id) do
    app_id
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp target_action_name(record) do
    record
    |> map_value("target_action")
    |> case do
      %{} = action -> string_value(action, "name") || string_value(action, :name)
      _other -> nil
    end
  end

  defp analysis_route(nil), do: nil
  defp analysis_route(analysis_id), do: "/apps/stocksage/analyses/#{safe_id(analysis_id)}"

  defp stocksage_surface_id(:analysis_card), do: :stocksage_analysis_card
  defp stocksage_surface_id(:agent_report_card), do: :stocksage_agent_report_card
  defp stocksage_surface_id(:debate_round_card), do: :stocksage_debate_round_card
  defp stocksage_surface_id(:parity_card), do: :stocksage_parity_card

  defp bounded_map(map) when is_map(map) do
    map
    |> normalize_map()
    |> drop_nil_values()
    |> Redactor.redact()
    |> Enum.take(64)
    |> Map.new(fn {key, value} -> {key, bounded_value(value)} end)
  end

  defp bounded_value(value) when is_binary(value), do: String.slice(value, 0, 1_500)
  defp bounded_value(value) when is_map(value), do: bounded_map(value)

  defp bounded_value(value) when is_list(value),
    do: value |> Enum.take(16) |> Enum.map(&bounded_value/1)

  defp bounded_value(value), do: value

  defp normalize_map(map) when is_map(map) do
    map
  end

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp string_value(map, key) when is_map(map) do
    map
    |> map_value(key)
    |> string_value()
  end

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: inspect(value, limit: 20, printable_limit: 1_000)

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      id -> String.slice(id, 0, 48)
    end
  end

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
