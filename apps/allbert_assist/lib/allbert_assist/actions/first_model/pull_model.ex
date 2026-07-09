defmodule AllbertAssist.Actions.FirstModel.PullModel do
  @moduledoc """
  Pull the curated default model (v0.62 M4, ADR 0078; M4 Authority Contract).

  Uses the local Ollama REST API (`POST /api/pull`) under the existing
  **`:external_network`** authority — its `:needs_confirmation` safety floor
  means the pull runs only behind a durable operator confirmation. The API path
  is loopback-only and returns a bounded JSON summary; there is no silent
  egress. The trace records the model tag and outcome.
  """

  use AllbertAssist.Action,
    permission: :external_network,
    exposure: :internal,
    execution_mode: :first_model_pull,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "pull_model",
    description: "Pull the curated default model via the local Ollama API (confirmation-gated).",
    category: "first_model",
    tags: ["first_model", "pull", "external_network", "confirmation"],
    schema: [
      model: [type: :string, required: false],
      dry_run: [type: :boolean, required: false],
      user_id: [type: :string, required: false],
      thread_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true],
      progress: [type: {:list, :map}, required: false]
    ]

  alias AllbertAssist.Actions.Support.ConfirmationRequest
  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Signals

  @req_options_key :first_model_req_options
  @progress_private_key :allbert_first_model_pull_progress

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:external_network, context)
    model = Map.get(params, :model) || Ollama.curated_model()
    progress_context = progress_context(params, context)

    cond do
      # dry_run is a pre-gate PREVIEW: no egress, just names the model + local
      # endpoint. Real pull is gated below.
      Map.get(params, :dry_run, false) ->
        {:ok,
         %{
           message: "Would pull #{model} via #{Ollama.base_url()}/api/pull",
           status: :completed,
           permission_decision: permission_decision,
           actions: [action(:completed, permission_decision, %{model: model, executed: false})]
         }}

      not PermissionGate.allowed?(permission_decision) and not approval_resume?(context) ->
        request_or_deny(permission_decision, model, progress_context, context)

      true ->
        pull(model, permission_decision, progress_context)
    end
  end

  # M8.14: persist a durable confirmation so `admin confirmations approve <id>`
  # completes the pull (resumed with the same `model`).
  defp request_or_deny(permission_decision, model, progress_context, context) do
    resume_params =
      %{model: model}
      |> maybe_put(:user_id, progress_context.user_id)
      |> maybe_put(:thread_id, progress_context.thread_id)

    attrs = %{
      target_action: %{name: name(), module: inspect(__MODULE__)},
      target_permission: :external_network,
      target_execution_mode: :first_model_pull,
      params_summary: %{model: model, endpoint: "#{Ollama.base_url()}/api/pull"},
      resume_params_ref: resume_params
    }

    case ConfirmationRequest.resolve(permission_decision, attrs, context) do
      {:needs_confirmation, confirmation} ->
        {:ok,
         %{
           message:
             "Model pull is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing was pulled.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             action(:needs_confirmation, permission_decision, %{
               model: model,
               executed: false,
               confirmation_id: confirmation["id"]
             })
           ]
         }}

      _denied ->
        denied(permission_decision, model)
    end
  end

  defp pull(model, permission_decision, progress_context) do
    case do_pull(model, progress_context) do
      {:ok, summary, progress} ->
        {:ok,
         %{
           message: "Pulled #{model}.",
           status: :completed,
           permission_decision: permission_decision,
           progress: progress,
           actions: [
             action(:completed, permission_decision, %{
               model: model,
               executed: true,
               summary: summary
             })
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Pull of #{model} failed: #{inspect(reason)}",
           status: :error,
           permission_decision: permission_decision,
           actions: [action(:error, permission_decision, %{model: model, error: inspect(reason)})]
         }}
    end
  end

  # Injectable puller for tests; default streams POST /api/pull progress.
  defp do_pull(model, progress_context) do
    puller = Application.get_env(:allbert_assist, :first_model_pull, &default_pull/2)

    case :erlang.fun_info(puller, :arity) do
      {:arity, 2} -> normalize_pull_result(puller.(model, progress_context))
      {:arity, 1} -> normalize_pull_result(puller.(model))
    end
  end

  defp default_pull(model, progress_context) do
    with {:ok, url} <- Ollama.local_url("/api/pull") do
      opts =
        [
          method: :post,
          url: url,
          json: %{name: model, stream: true},
          into: stream_collector(model, progress_context),
          decode_body: false,
          receive_timeout: 600_000,
          retry: false,
          redirect: false
        ]
        |> Keyword.merge(Application.get_env(:allbert_assist, @req_options_key, []))

      case Req.request(opts) do
        {:ok, %{status: 200} = resp} ->
          {events, progress} =
            resp
            |> collector()
            |> flush_collector(model, progress_context)

          {:ok, summarize_events(events), progress}

        {:ok, %{status: code}} ->
          {:error, {:http, code}}

        {:error, %Req.TransportError{} = error} ->
          {:error, error.reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_pull_result({:ok, summary, progress}), do: {:ok, summary, progress}
  defp normalize_pull_result({:ok, summary}), do: {:ok, summary, []}
  defp normalize_pull_result({:error, reason}), do: {:error, reason}

  defp stream_collector(model, progress_context) do
    fn {:data, data}, {req, resp} ->
      {collector, _progress} =
        resp
        |> collector()
        |> collect_chunk(data, model, progress_context)

      {:cont, {req, %{resp | private: Map.put(resp.private, @progress_private_key, collector)}}}
    end
  end

  defp collector(%{private: private}) when is_map(private),
    do: Map.get(private, @progress_private_key, empty_collector())

  defp collector(_response), do: empty_collector()

  defp empty_collector, do: %{buffer: "", events: [], progress: []}

  defp collect_chunk(collector, data, model, progress_context) when is_binary(data) do
    lines =
      (collector.buffer <> data)
      |> String.split("\n")

    {complete, rest} =
      case lines do
        [] -> {[], ""}
        [_one] -> {[], List.first(lines)}
        many -> {Enum.drop(many, -1), List.last(many)}
      end

    collect_lines(%{collector | buffer: rest}, complete, model, progress_context)
  end

  defp collect_chunk(collector, _data, _model, _progress_context), do: {collector, []}

  defp flush_collector(%{buffer: ""} = collector, _model, _progress_context),
    do: {collector.events, collector.progress}

  defp flush_collector(collector, model, progress_context) do
    {collector, _progress} =
      collect_lines(%{collector | buffer: ""}, [collector.buffer], model, progress_context)

    {collector.events, collector.progress}
  end

  defp collect_lines(collector, lines, model, progress_context) do
    {events, progress} =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({[], []}, fn line, {events_acc, progress_acc} ->
        case Jason.decode(line) do
          {:ok, %{} = event} ->
            progress = progress_event(model, event, progress_context)
            emit_progress(progress)
            {[event | events_acc], [progress | progress_acc]}

          _invalid ->
            {events_acc, progress_acc}
        end
      end)

    {
      %{
        collector
        | events: collector.events ++ Enum.reverse(events),
          progress: collector.progress ++ Enum.reverse(progress)
      },
      Enum.reverse(progress)
    }
  end

  defp progress_event(model, event, progress_context) do
    total = number_value(event, "total")
    completed = number_value(event, "completed")

    %{
      model: model,
      user_id: progress_context.user_id,
      thread_id: progress_context.thread_id,
      status: text_value(event, "status") || "pulling",
      digest: text_value(event, "digest"),
      total: total,
      completed: completed,
      percent: percent(completed, total)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp emit_progress(%{user_id: user_id, thread_id: thread_id} = progress)
       when is_binary(user_id) and user_id != "" and is_binary(thread_id) and thread_id != "" do
    Signals.emit_first_model_pull_progress(progress)
  end

  defp emit_progress(_progress), do: :ok

  defp summarize_events([]), do: %{status: "completed"}

  defp summarize_events(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&event_status/1)
    |> case do
      nil -> %{status: "completed"}
      status -> %{status: status}
    end
  end

  defp event_status(%{"status" => status}) when is_binary(status), do: status
  defp event_status(%{status: status}) when is_binary(status), do: status
  defp event_status(_event), do: nil

  defp denied(permission_decision, model) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{model: model, executed: false})]
     }}
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp progress_context(params, context) do
    %{
      user_id:
        first_present([
          Map.get(params, :user_id),
          Map.get(params, "user_id"),
          context_value(context, :user_id),
          context_value(context, :actor),
          request_value(context, :user_id),
          request_value(context, :operator_id)
        ]),
      thread_id:
        first_present([
          Map.get(params, :thread_id),
          Map.get(params, "thread_id"),
          context_value(context, :thread_id),
          request_value(context, :thread_id)
        ])
    }
  end

  defp context_value(context, key) when is_map(context),
    do: map_value(context, key)

  defp request_value(context, key) when is_map(context) do
    case Map.get(context, :request) || Map.get(context, "request") do
      request when is_map(request) -> map_value(request, key)
      _other -> nil
    end
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp text_value(map, key) when is_map(map) do
    case map_value(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp number_value(map, key) when is_map(map) do
    case map_value(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> value
      _other -> nil
    end
  end

  defp map_value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp percent(completed, total) when is_number(completed) and is_number(total) and total > 0 do
    Float.round(completed / total * 100, 1)
  end

  defp percent(_completed, _total), do: nil

  defp action(status, permission_decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :external_network,
        permission_decision: permission_decision
      },
      metadata
    )
  end
end
