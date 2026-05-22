defmodule StockSage.Progress do
  @moduledoc """
  Bounded Phoenix.PubSub progress events for StockSage-owned LiveViews.

  This is an app-surface convenience channel, not a durable SignalBus subject.
  Persisted analysis/objective state remains the reconnect source of truth.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Signals

  @pubsub AllbertAssist.PubSub
  @topic_prefix "stocksage_progress:"
  @max_id 96
  @max_stage 32
  @max_status 32
  @max_summary 240
  @allowed_stages ~w[
    analyst
    debate
    risk
    synthesis
    parity
    queued
    running
    completed
    failed
    update
  ]

  @type payload :: %{
          id: String.t(),
          analysis_id: String.t() | nil,
          objective_id: String.t() | nil,
          stage: String.t(),
          status: String.t(),
          summary: String.t() | nil,
          at: String.t()
        }

  @spec topic(String.t(), String.t()) :: String.t()
  def topic(user_id, analysis_id) when is_binary(user_id) and is_binary(analysis_id) do
    @topic_prefix <> safe_topic_part(user_id) <> ":" <> safe_topic_part(analysis_id)
  end

  @spec subscribe(String.t(), String.t()) :: :ok
  def subscribe(user_id, analysis_id) when is_binary(user_id) and is_binary(analysis_id) do
    if enabled?() and not blank?(user_id) and not blank?(analysis_id) do
      Phoenix.PubSub.subscribe(@pubsub, topic(user_id, analysis_id))
    end

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  @spec unsubscribe_topic(String.t() | nil) :: :ok
  def unsubscribe_topic(topic) when is_binary(topic) and topic != "" do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  def unsubscribe_topic(_topic), do: :ok

  @spec broadcast(String.t(), String.t(), map()) :: :ok
  def broadcast(user_id, analysis_id, payload)
      when is_binary(user_id) and is_binary(analysis_id) and is_map(payload) do
    if enabled?() and not blank?(user_id) and not blank?(analysis_id) do
      normalized =
        payload
        |> Map.put_new(:analysis_id, analysis_id)
        |> normalize_payload()

      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(user_id, analysis_id),
        {:stocksage_progress, normalized}
      )
    end

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  def broadcast(_user_id, _analysis_id, _payload), do: :ok

  @spec normalize_payload(map()) :: payload()
  def normalize_payload(payload) when is_map(payload) do
    raw_at = value(payload, :at)
    redacted = Signals.redact(payload)
    analysis_id = value(redacted, :analysis_id)
    objective_id = value(redacted, :objective_id)
    stage = normalized_stage(value(redacted, :stage))
    status = bounded(value(redacted, :status) || stage, @max_status)
    summary = bounded(value(redacted, :summary), @max_summary)
    at = normalized_at(raw_at || value(redacted, :at))

    %{
      id: bounded(value(redacted, :id) || stable_id(analysis_id, stage, status, at), @max_id),
      analysis_id: bounded(analysis_id, @max_id),
      objective_id: bounded(objective_id, @max_id),
      stage: stage,
      status: status,
      summary: summary,
      at: at
    }
  end

  def normalize_payload(_payload), do: normalize_payload(%{})

  @spec persisted_items(map() | nil, [map()]) :: [payload()]
  def persisted_items(nil, _steps), do: []

  def persisted_items(analysis, steps) when is_map(analysis) do
    step_items =
      steps
      |> List.wrap()
      |> Enum.take(12)
      |> Enum.with_index(1)
      |> Enum.map(fn {step, index} ->
        normalize_payload(%{
          id: "step-#{value(step, :id) || index}",
          analysis_id: value(analysis, :id),
          objective_id: value(analysis, :objective_id),
          stage: "analyst",
          status: value(step, :status) || "observed",
          summary:
            value(step, :result_summary) ||
              value(step, :delegate_agent_id) ||
              value(step, :kind) ||
              "Objective step observed.",
          at: value(step, :updated_at) || value(step, :inserted_at)
        })
      end)

    final_item =
      normalize_payload(%{
        id: "analysis-#{value(analysis, :id)}-#{value(analysis, :status) || "current"}",
        analysis_id: value(analysis, :id),
        objective_id: value(analysis, :objective_id),
        stage: final_stage(value(analysis, :status)),
        status: value(analysis, :status) || "current",
        summary: value(analysis, :summary) || "Analysis state loaded.",
        at: value(analysis, :updated_at) || value(analysis, :inserted_at)
      })

    step_items ++ [final_item]
  end

  def persisted_items(_analysis, _steps), do: []

  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.get("stocksage.web.progress_stream_enabled") do
      {:ok, value} when is_boolean(value) -> value
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp final_stage("completed"), do: "completed"
  defp final_stage("failed"), do: "failed"
  defp final_stage("running"), do: "running"
  defp final_stage(_status), do: "update"

  defp normalized_stage(stage) when is_binary(stage) do
    stage = stage |> String.downcase() |> bounded(@max_stage)

    if stage in @allowed_stages, do: stage, else: "update"
  end

  defp normalized_stage(stage) when is_atom(stage), do: normalized_stage(Atom.to_string(stage))
  defp normalized_stage(_stage), do: "update"

  defp normalized_at(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp normalized_at(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp normalized_at(at) when is_binary(at) and at != "", do: bounded(at, 48)
  defp normalized_at(_at), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp stable_id(analysis_id, stage, status, at) do
    [analysis_id || "analysis", stage, status, at]
    |> Enum.join("-")
    |> String.replace(~r/[^a-zA-Z0-9:_-]/, "-")
  end

  defp safe_topic_part(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.slice(0, @max_id)
  end

  defp bounded(nil, _max), do: nil

  defp bounded(value, max) when is_binary(value) do
    if byte_size(value) > max, do: binary_part(value, 0, max), else: value
  end

  defp bounded(value, max), do: value |> inspect() |> bounded(max)

  defp blank?(value), do: String.trim(value) == ""

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp value(_map, _key), do: nil
end
