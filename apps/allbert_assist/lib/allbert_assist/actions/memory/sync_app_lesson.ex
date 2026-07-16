defmodule AllbertAssist.Actions.Memory.SyncAppLesson do
  @moduledoc """
  Explicitly sync an app-owned lesson into durable Allbert markdown memory.

  The write path is intentionally generic and namespace-checked. v0.29's first
  caller is StockSage, but the authority comes from the app registry's memory
  namespace declaration and the Security Central memory-write boundary.
  """

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :app_memory_sync,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    notes:
      "Writes one explicitly confirmed app lesson through a declared writable app memory namespace.",
    name: "sync_app_lesson",
    description: "Sync one reviewed app lesson into namespaced Allbert markdown memory.",
    category: "memory",
    tags: ["memory", "app", "lesson", "confirmation"],
    schema: [
      user_id: [type: :string, required: false],
      app_id: [type: :string, required: true],
      namespace: [type: :string, required: true],
      analysis_id: [type: :string, required: true],
      outcome_id: [type: :string, required: false],
      objective_id: [type: :string, required: false],
      ticker: [type: :string, required: true],
      rating: [type: :string, required: false],
      realized_return: [type: :string, required: false],
      holding_period_days: [type: :integer, required: true],
      lesson_text: [type: :string, required: true],
      source: [type: :string, required: false],
      resolved_at: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      memory: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Maps
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Security.PermissionGate

  @kind "stocksage_lesson"
  @max_lesson_text_length 4_000
  @truncation_notice "\n\n[Lesson text truncated to 4000 characters before memory sync.]"

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    security_context = memory_sync_context(context)
    permission_decision = PermissionGate.authorize(:memory_write, security_context)

    with {:ok, attrs} <- normalize_attrs(params, context) do
      cond do
        PermissionGate.allowed?(permission_decision) ->
          write_lesson(attrs, context, permission_decision)

        permission_decision.requires_confirmation ->
          create_confirmation(attrs, context, permission_decision)

        true ->
          denied(permission_decision)
      end
    else
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  def run(_params, context), do: run(%{}, context)

  defp write_lesson(attrs, context, permission_decision) do
    memory_attrs = %{
      category: :notes,
      summary: lesson_summary(attrs),
      body: lesson_body(attrs),
      actor: attrs.user_id,
      agent: inspect(__MODULE__),
      channel: context_value(context, :channel, "app"),
      source_signal_id: context_value(context, :runner_requested_signal_id, "unknown"),
      app_id: attrs.app_id,
      namespace: attrs.namespace,
      kind: @kind,
      idempotency_key: attrs.idempotency_key,
      source_ref: attrs.source_ref
    }

    case Memory.upsert_app_entry(memory_attrs) do
      {:ok, %Entry{} = entry} ->
        memory = Entry.to_map(entry)

        {:ok,
         %{
           message: "Synced #{attrs.app_id} lesson into #{attrs.namespace} memory.",
           status: :completed,
           permission_decision: permission_decision,
           memory: memory,
           actions: [
             action(:completed, permission_decision, %{
               execution: :completed,
               memory_path: entry.path,
               app_id: attrs.app_id,
               namespace: attrs.namespace,
               kind: @kind,
               idempotency_key: attrs.idempotency_key,
               source_ref: attrs.source_ref
             })
           ]
         }}

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp create_confirmation(attrs, context, permission_decision) do
    preview = attrs.lesson_text |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)

    case Confirmations.create(%{
           origin: origin(context, attrs),
           target_action: %{name: "sync_app_lesson", module: inspect(__MODULE__)},
           target_permission: :memory_write,
           target_execution_mode: :app_memory_sync,
           security_decision: permission_decision,
           params_summary: %{
             user_id: attrs.user_id,
             app_id: attrs.app_id,
             namespace: attrs.namespace,
             kind: @kind,
             analysis_id: attrs.analysis_id,
             outcome_id: attrs.outcome_id,
             objective_id: attrs.objective_id,
             ticker: attrs.ticker,
             idempotency_key: attrs.idempotency_key,
             source_ref: attrs.source_ref,
             lesson_preview: preview
           },
           resume_params_ref: Map.take(attrs, resume_keys())
         }) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "App lesson sync requires confirmation. Confirmation request: #{confirmation["id"]}. No Allbert markdown memory was written.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             action(:needs_confirmation, permission_decision, %{
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               app_id: attrs.app_id,
               namespace: attrs.namespace,
               kind: @kind,
               idempotency_key: attrs.idempotency_key,
               source_ref: attrs.source_ref
             })
           ]
         }}

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{execution: :not_started})]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to sync app lesson: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, %{error: reason})]
     }}
  end

  defp normalize_attrs(params, context) do
    with {:ok, user_id} <- Context.user_id(params, context),
         {:ok, app_id} <- required(params, :app_id),
         {:ok, namespace} <- required(params, :namespace),
         {:ok, analysis_id} <- required(params, :analysis_id),
         {:ok, ticker} <- required(params, :ticker),
         {:ok, holding_period_days} <- positive_integer(params, :holding_period_days),
         {:ok, lesson_text} <- required(params, :lesson_text) do
      attrs = %{
        user_id: user_id,
        app_id: app_id,
        namespace: namespace,
        analysis_id: analysis_id,
        outcome_id: optional(params, :outcome_id),
        objective_id: optional(params, :objective_id),
        ticker: String.upcase(ticker),
        rating: optional(params, :rating) || "unrated",
        realized_return: optional(params, :realized_return) || "unknown",
        holding_period_days: holding_period_days,
        lesson_text: normalize_lesson_text(lesson_text),
        source: optional(params, :source) || "app_lesson_sync",
        resolved_at: optional(params, :resolved_at) || now_iso8601()
      }

      {:ok,
       attrs
       |> Map.put(:idempotency_key, idempotency_key(attrs))
       |> Map.put(:source_ref, source_ref(attrs))}
    end
  end

  defp memory_sync_context(%{confirmation: %{approved?: true}} = context), do: context
  defp memory_sync_context(%{"confirmation" => %{"approved?" => true}} = context), do: context

  defp memory_sync_context(context) do
    context
    |> Map.put(:advisory, %{
      present?: true,
      source: :app_lesson_sync,
      provider: context_value(context, :active_app, :app)
    })
    |> Map.put(:advisory_output?, true)
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "sync_app_lesson",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp lesson_summary(attrs) do
    "#{attrs.ticker} #{attrs.holding_period_days}d #{attrs.rating} lesson"
  end

  defp lesson_body(attrs) do
    """
    ## App Lesson

    - App: #{attrs.app_id}
    - Namespace: #{attrs.namespace}
    - Kind: #{@kind}
    - Ticker: #{attrs.ticker}
    - Rating: #{attrs.rating}
    - Realized return: #{attrs.realized_return}
    - Holding period days: #{attrs.holding_period_days}
    - Analysis ID: #{attrs.analysis_id}
    - Outcome ID: #{attrs.outcome_id || "not recorded"}
    - Objective ID: #{attrs.objective_id || "not recorded"}
    - Source: #{attrs.source}
    - Resolved at: #{attrs.resolved_at}

    #{attrs.lesson_text}
    """
    |> String.trim()
  end

  defp idempotency_key(attrs),
    do: "#{attrs.app_id}:#{attrs.analysis_id}:#{attrs.holding_period_days}d"

  defp source_ref(attrs), do: "#{attrs.app_id}:analysis:#{attrs.analysis_id}"

  defp required(params, key) do
    case optional(params, key) do
      nil -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  defp optional(params, key) do
    params
    |> field(key)
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_integer(value) or is_float(value) ->
        to_string(value)

      _value ->
        nil
    end
  end

  defp positive_integer(params, key) do
    case field(params, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_positive_integer(value, key)
      _value -> {:error, {:missing_required, key}}
    end
  end

  defp parse_positive_integer(value, key) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp field(map, key), do: Maps.field(map, key)

  defp context_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp normalize_lesson_text(text) do
    text
    |> redact_lesson()
    |> String.trim()
    |> bound_lesson_text()
  end

  defp bound_lesson_text(text) do
    if String.length(text) <= @max_lesson_text_length do
      text
    else
      slice_length = @max_lesson_text_length - String.length(@truncation_notice)

      text
      |> String.slice(0, slice_length)
      |> Kernel.<>(@truncation_notice)
    end
  end

  defp redact_lesson(text), do: String.replace(text, ~r/secret:\/\/[^\s]+/, "[SECRET_REF]")

  defp origin(context, attrs) do
    %{
      channel: context_value(context, :channel, :unknown),
      actor: context_value(context, :actor, attrs.user_id),
      user_id: attrs.user_id,
      app_id: attrs.app_id,
      objective_id: attrs.objective_id,
      session_id: context_value(context, :session_id, nil),
      surface: context_value(context, :surface, "action")
    }
  end

  defp resume_keys do
    [
      :user_id,
      :app_id,
      :namespace,
      :analysis_id,
      :outcome_id,
      :objective_id,
      :ticker,
      :rating,
      :realized_return,
      :holding_period_days,
      :lesson_text,
      :source,
      :resolved_at
    ]
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
