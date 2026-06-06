defmodule Mix.Tasks.Allbert.SelfImprovement do
  @moduledoc """
  Inspect self-improvement suggestions and inert drafts.

  ## Usage

      mix allbert.self_improvement list
      mix allbert.self_improvement inspect <suggestion_id>
      mix allbert.self_improvement drafts list
      mix allbert.self_improvement drafts inspect <draft_id>
      mix allbert.self_improvement drafts discard <draft_id>
  """

  use Mix.Task

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Tools.Discovery

  @shortdoc "Inspect self-improvement suggestions and drafts"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [kind: :string, status: :string, limit: :integer],
        aliases: [k: :kind, s: :status, l: :limit]
      )

    case {rest, invalid} do
      {[], []} ->
        status = Keyword.get(opts, :status, "pending")
        limit = Keyword.get(opts, :limit, 25)
        kind = Keyword.get(opts, :kind)

        suggestions =
          [status: status, provenance: "self_improvement", limit: limit]
          |> Discovery.list_suggestions()
          |> filter_kind(kind)

        {:ok, {:list, suggestions}}

      _other ->
        {:error, :invalid_list_args}
    end
  end

  defp dispatch(["inspect", suggestion_id]) do
    with {:ok, suggestion} <- Discovery.get_suggestion(suggestion_id) do
      {:ok, {:inspect, suggestion}}
    end
  end

  defp dispatch(["drafts", "list" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [kind: :string],
        aliases: [k: :kind]
      )

    case {rest, invalid} do
      {[], []} -> {:ok, {:drafts_list, Store.list_drafts(kind: Keyword.get(opts, :kind))}}
      _other -> {:error, :invalid_drafts_list_args}
    end
  end

  defp dispatch(["drafts", "inspect", draft_id]) do
    with {:ok, draft} <- Store.show_draft(draft_id) do
      {:ok, {:drafts_inspect, draft}}
    end
  end

  defp dispatch(["drafts", "discard", draft_id]) do
    with {:ok, draft} <- Store.discard_draft(draft_id) do
      {:ok, {:drafts_discard, draft}}
    end
  end

  defp dispatch(_args), do: {:error, :usage}

  defp print_result({:ok, {:list, suggestions}}) do
    Mix.shell().info("Self-improvement suggestions: #{length(suggestions)}")

    Enum.each(suggestions, fn suggestion ->
      metadata = Map.get(suggestion, :metadata, %{})

      Mix.shell().info(
        "- #{suggestion.id} #{suggestion.status} #{suggestion.suggestion_type} #{Map.get(metadata, "proposed_draft_kind", "draft")}"
      )

      summary = Map.get(metadata, "summary")
      if is_binary(summary) and summary != "", do: Mix.shell().info("  #{summary}")
    end)
  end

  defp print_result({:ok, {:inspect, suggestion}}) do
    metadata = Map.get(suggestion, :metadata, %{})

    Mix.shell().info("id=#{suggestion.id}")
    Mix.shell().info("status=#{suggestion.status}")
    Mix.shell().info("suggestion_type=#{suggestion.suggestion_type}")
    Mix.shell().info("provenance=#{suggestion.provenance}")
    Mix.shell().info("draft_id=#{suggestion.draft_id || "none"}")
    Mix.shell().info("expires_at=#{suggestion.expires_at || "none"}")
    Mix.shell().info("summary=#{Map.get(metadata, "summary", "")}")
    Mix.shell().info("proposed_draft_kind=#{Map.get(metadata, "proposed_draft_kind", "")}")
    Mix.shell().info("evidence_refs=#{inspect(Map.get(metadata, "evidence_refs", []))}")
  end

  defp print_result({:ok, {:drafts_list, drafts}}) do
    Mix.shell().info("Self-improvement drafts: #{length(drafts)}")

    Enum.each(drafts, fn draft ->
      Mix.shell().info("- #{draft.id} #{draft.kind} #{draft.tier} #{draft.artifact_path || ""}")
    end)
  end

  defp print_result({:ok, {:drafts_inspect, draft}}) do
    Mix.shell().info("id=#{draft.id}")
    Mix.shell().info("kind=#{draft.kind}")
    Mix.shell().info("tier=#{draft.tier}")
    Mix.shell().info("live_authority=#{draft.live_authority}")
    Mix.shell().info("source_suggestion_id=#{draft.source_suggestion_id || "none"}")
    Mix.shell().info("artifact_path=#{draft.artifact_path || "none"}")
  end

  defp print_result({:ok, {:drafts_discard, draft}}) do
    Mix.shell().info("Discarded self-improvement draft #{draft.id}.")
    Mix.shell().info("tier=#{draft.tier}")
  end

  defp print_result({:error, :usage}) do
    Mix.raise("""
    Usage:
      mix allbert.self_improvement list [--kind KIND] [--status STATUS] [--limit N]
      mix allbert.self_improvement inspect <suggestion_id>
      mix allbert.self_improvement drafts list [--kind KIND]
      mix allbert.self_improvement drafts inspect <draft_id>
      mix allbert.self_improvement drafts discard <draft_id>
    """)
  end

  defp print_result({:error, :invalid_list_args}), do: Mix.raise("Invalid list arguments.")

  defp print_result({:error, :invalid_drafts_list_args}),
    do: Mix.raise("Invalid drafts list arguments.")

  defp print_result({:error, :not_found}), do: Mix.raise("Suggestion not found.")

  defp print_result({:error, reason}),
    do: Mix.raise("Self-improvement command failed: #{inspect(reason)}")

  defp filter_kind(suggestions, nil), do: suggestions

  defp filter_kind(suggestions, kind) do
    Enum.filter(suggestions, &(&1.suggestion_type == kind))
  end
end
