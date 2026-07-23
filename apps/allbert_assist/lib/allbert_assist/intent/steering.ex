defmodule AllbertAssist.Intent.Steering do
  @moduledoc """
  Deterministic stage-zero classifier for turns addressed to active fan-outs.

  Mutating intents require an unambiguous child. Status is read-only and may
  aggregate. Free text is never interpreted as confirmation approval.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout

  @active ~w[open running blocked]
  @status ~r/^\s*(?:status|progress|how(?:'s| is)|what(?:'s| is) the status)\b/iu
  @cancel ~r/^\s*(?:cancel|stop|skip)\b/iu
  @steer ~r/^\s*(?:steer|adjust|change|redirect|revise|instead|actually|make)\b/iu
  @approval ~r/^\s*(?:approve|deny)\s+(?:confirmation\s+)?[A-Za-z0-9_-]+\s*$/iu

  @spec handle(map()) :: :not_steering | {:ok, map()}
  def handle(%{coding_turn?: true}), do: :not_steering

  def handle(request) do
    parents = active_parents(request)

    case classify(request.text, parents) do
      :new_request -> :not_steering
      :not_steering -> :not_steering
      {:status, targets} -> {:ok, status_response(targets)}
      {:clarify, message} -> {:ok, response(message, :clarification)}
      {:cancel, [target]} -> run_cancel(request, target)
      {:steer, [target]} -> run_steer(request, target)
    end
  end

  def classify(text, parents), do: classify(text, parents, [])

  @spec classify(String.t(), [map()], keyword()) :: term()
  def classify(text, parents, opts) when is_binary(text) and is_list(parents) do
    cond do
      parents == [] -> :not_steering
      Regex.match?(@approval, text) -> :new_request
      Regex.match?(@status, text) -> {:status, status_targets(text, parents)}
      Regex.match?(@cancel, text) -> mutation(:cancel, text, parents)
      Regex.match?(@steer, text) -> mutation(:steer, text, parents)
      true -> assisted_classification(text, parents, opts)
    end
  end

  defp assisted_classification(text, parents, opts) do
    case Keyword.get(opts, :model_assist) do
      fun when is_function(fun, 2) ->
        case fun.(text, Enum.flat_map(parents, &Fanout.children/1)) do
          :status -> {:status, status_targets(text, parents)}
          kind when kind in [:cancel, :steer] -> mutation(kind, text, parents)
          _ -> :new_request
        end

      _ ->
        :new_request
    end
  end

  defp mutation(kind, text, parents) do
    targets = resolve_targets(text, parents)

    case targets do
      [target] -> {kind, [target]}
      [] -> {:clarify, "Which active task do you mean? Reply with its number or title."}
      _ -> {:clarify, "That matches more than one active task. Reply with its number or title."}
    end
  end

  defp status_targets(text, parents) do
    case resolve_targets(text, parents) do
      [] -> Enum.flat_map(parents, &Fanout.children/1)
      targets -> targets
    end
  end

  defp resolve_targets(text, parents) do
    children = Enum.flat_map(parents, &Fanout.children/1)
    normalized = normalize(text)

    case ordinal(normalized) do
      nil ->
        title_matches(normalized, children)

      index ->
        children
        |> Enum.sort_by(&{&1.parent_objective_id, &1.queue_position})
        |> Enum.at(index)
        |> List.wrap()
    end
  end

  defp ordinal(text) do
    cond do
      Regex.match?(~r/\b(?:first|one|1|#1)\b/u, text) -> 0
      Regex.match?(~r/\b(?:second|two|2|#2)\b/u, text) -> 1
      Regex.match?(~r/\b(?:third|three|3|#3)\b/u, text) -> 2
      Regex.match?(~r/\b(?:fourth|four|4|#4)\b/u, text) -> 3
      true -> nil
    end
  end

  defp title_matches(text, children) do
    Enum.filter(children, fn child ->
      title = normalize(child.title || "")
      title != "" and (String.contains?(text, title) or overlap(text, title) >= 0.6)
    end)
  end

  defp overlap(left, right) do
    left = left |> tokens() |> MapSet.new()
    right = right |> tokens() |> MapSet.new()

    if MapSet.size(right) == 0,
      do: 0.0,
      else: MapSet.size(MapSet.intersection(left, right)) / MapSet.size(right)
  end

  defp tokens(text),
    do:
      String.split(text) --
        ~w[status progress cancel stop skip steer adjust change redirect revise instead actually make task research the a an]

  defp normalize(text),
    do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}#]+/u, " ") |> String.trim()

  defp active_parents(request) do
    request.user_id
    |> Objectives.list_objectives(
      source_thread_id: request.thread_id,
      statuses: @active,
      limit: 20
    )
    |> Enum.filter(&(&1.fanout_role == "parent"))
  end

  defp run_cancel(request, target) do
    {:ok, result} =
      Runner.run(
        "cancel_objective_run",
        %{objective_id: target.id, reason: request.text},
        action_context(request)
      )

    {:ok, result}
  end

  defp run_steer(request, target) do
    {:ok, result} =
      Runner.run(
        "steer_objective_run",
        %{objective_id: target.id, directive: request.text},
        action_context(request)
      )

    {:ok, result}
  end

  defp status_response(targets) do
    lines =
      Enum.map(
        targets,
        &"#{(&1.queue_position || 0) + 1}. #{&1.title}: #{&1.status} — #{&1.progress_summary || "No progress recorded yet."}"
      )

    response(Enum.join(lines, "\n"), :status)
  end

  defp response(message, status), do: %{message: message, status: status, actions: []}

  defp action_context(request),
    do: %{user_id: request.user_id, channel: request.channel, thread_id: request.thread_id}
end
