defmodule AllbertAssist.Workspace.Emitters do
  @moduledoc """
  Best-effort workspace fragment emitters for durable runtime events.

  This module does not own persistence. It turns already-authoritative
  confirmation, objective, and app-analysis events into signed catalog-bound
  fragments that the workspace shell may render.
  """

  require Logger

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Events
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @confirmation_emitter "AllbertAssist.Confirmations"
  @objective_emitter "AllbertAssist.Objectives"
  @stocksage_emitter "StockSage.Actions.RunAnalysis"

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
      "/agent",
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
      "/agent",
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
      "/stocksage",
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

  defp payload_context(payload) do
    context(string_value(payload, :user_id), string_value(payload, :thread_id))
  end

  defp context(user_id, thread_id)
       when is_binary(user_id) and user_id != "" and is_binary(thread_id) and thread_id != "" do
    {:ok, %{user_id: user_id, thread_id: thread_id}}
  end

  defp context(_user_id, _thread_id), do: {:error, :missing_workspace_context}

  defp target_action_name(record) do
    record
    |> map_value("target_action")
    |> case do
      %{} = action -> string_value(action, "name") || string_value(action, :name)
      _other -> nil
    end
  end

  defp analysis_route(nil), do: nil
  defp analysis_route(analysis_id), do: "/stocksage/analyses/#{safe_id(analysis_id)}"

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
