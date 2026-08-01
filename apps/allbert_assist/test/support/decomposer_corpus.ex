defmodule AllbertAssist.TestSupport.DecomposerCorpus do
  @moduledoc "Deterministic 200-row corpus for the frozen counted fanout protocol."

  @surfaces ~w[tui web telegram email discord slack matrix whatsapp signal cli openai_api acp_stdio jobs]

  def cases do
    positives() ++ single_negatives() ++ steering_negatives()
  end

  defp positives do
    for index <- 1..50 do
      {text, expected_tasks} = positive(index)

      %{
        id: "fanout-positive-#{pad(index)}",
        label: :fanout,
        surface: surface(index),
        text: text,
        context: %{expected_tasks: expected_tasks}
      }
    end
  end

  defp positive(index) when rem(index, 5) == 0 do
    left = "Research option #{index}"
    right = "summarize risk #{index}"
    third = "draft recommendation #{index}"
    {"Do these three tasks in parallel: #{left}; #{right}; #{third}", [left, right, third]}
  end

  defp positive(index) when rem(index, 2) == 0 do
    left = "Compare provider #{index}"
    right = "draft rollout #{index}"
    {"Do these two tasks in parallel: #{left}; #{right}", [left, right]}
  end

  defp positive(index) do
    left = "Inspect queue #{index}"
    right = "Write report #{index}"

    {"Do two things: #{left} and #{right}. Work on them in parallel and report back.",
     [left, right]}
  end

  defp single_negatives do
    templates = [
      "Summarize this supplied sentence for case &1: Project Juniper might begin after 2026-06-01; it is not approved, and it has no budget.",
      "Summarize this supplied checklist for case &1:\n1. Restart service &1.\n2. Delete cache &1.",
      "Explain this supplied sequence for case &1: inspect queue &1 and then delete cache &1.",
      "Draft one cohesive response about topic &1",
      "Research and summarize together for case &1",
      "Show channel configuration &1",
      "Help me understand retry safety &1",
      "Review this function without splitting case &1",
      "Write a concise note for case &1",
      "How should I approach migration &1?"
    ]

    for index <- 1..100 do
      template = Enum.at(templates, rem(index - 1, length(templates)))

      %{
        id: "single-negative-#{pad(index)}",
        label: :single,
        surface: surface(index),
        text: String.replace(template, "&1", Integer.to_string(index)),
        context: %{}
      }
    end
  end

  defp steering_negatives do
    verbs = ["status", "progress", "cancel", "stop", "pause", "resume", "retry", "skip"]

    for index <- 1..50 do
      verb = Enum.at(verbs, rem(index - 1, length(verbs)))

      %{
        id: "steering-negative-#{pad(index)}",
        label: :single,
        surface: surface(index),
        text: "#{verb} child #{index} and then tell me what remains",
        context: %{active_fanout?: true, steering_turn?: true}
      }
    end
  end

  defp surface(index), do: Enum.at(@surfaces, rem(index - 1, length(@surfaces)))
  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")
end
