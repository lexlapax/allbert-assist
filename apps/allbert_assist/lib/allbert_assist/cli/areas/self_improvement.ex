defmodule AllbertAssist.CLI.Areas.SelfImprovement do
  @moduledoc """
  Release-safe `self-improvement` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.self_improvement` and
  `allbert admin self-improvement`: `dispatch/2` parses the sub-argv, routes to
  the same read/store helpers the Mix task used, and returns `{rendered_output,
  exit_code}` — no `Mix.*` calls, so it runs inside the packaged release.
  `Mix.Tasks.Allbert.SelfImprovement` is a thin wrapper that prints the output
  through `Mix.shell/0`.

  These subcommands are bounded reads plus one inert-draft discard. The reads stay
  direct; the discard routes through `AllbertAssist.Actions.Runner.run/3` (via the
  `discard_self_improvement_draft` action) so the mutation clears PermissionGate +
  audit on the one spine (v0.62 M8.15).
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Tools.Discovery

  @usage """
  Usage:
    mix allbert.self_improvement list [--kind KIND] [--status STATUS] [--limit N]
    mix allbert.self_improvement inspect <suggestion_id>
    mix allbert.self_improvement drafts list [--kind KIND]
    mix allbert.self_improvement drafts inspect <draft_id>
    mix allbert.self_improvement drafts discard <draft_id>
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin self-improvement")

  defp route(["list" | args], _ctx) do
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

  defp route(["inspect", suggestion_id], _ctx) do
    with {:ok, suggestion} <- Discovery.get_suggestion(suggestion_id) do
      {:ok, {:inspect, suggestion}}
    end
  end

  defp route(["drafts", "list" | args], _ctx) do
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

  defp route(["drafts", "inspect", draft_id], _ctx) do
    with {:ok, draft} <- Store.show_draft(draft_id) do
      {:ok, {:drafts_inspect, draft}}
    end
  end

  defp route(["drafts", "discard", draft_id], ctx) do
    with {:ok, response} <-
           ActionHelper.completed_action(
             "discard_self_improvement_draft",
             %{id: draft_id},
             ctx
           ) do
      {:ok, {:drafts_discard, response.draft}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:list, suggestions}}) do
    Render.ok(
      ["Self-improvement suggestions: #{length(suggestions)}"] ++
        Enum.flat_map(suggestions, fn suggestion ->
          metadata = Map.get(suggestion, :metadata, %{})

          line =
            "- #{suggestion.id} #{suggestion.status} #{suggestion.suggestion_type} #{Map.get(metadata, "proposed_draft_kind", "draft")}"

          summary = Map.get(metadata, "summary")

          if is_binary(summary) and summary != "" do
            [line, "  #{summary}"]
          else
            [line]
          end
        end)
    )
  end

  defp render({:ok, {:inspect, suggestion}}) do
    metadata = Map.get(suggestion, :metadata, %{})

    Render.ok([
      "id=#{suggestion.id}",
      "status=#{suggestion.status}",
      "suggestion_type=#{suggestion.suggestion_type}",
      "provenance=#{suggestion.provenance}",
      "draft_id=#{suggestion.draft_id || "none"}",
      "expires_at=#{suggestion.expires_at || "none"}",
      "summary=#{Map.get(metadata, "summary", "")}",
      "proposed_draft_kind=#{Map.get(metadata, "proposed_draft_kind", "")}",
      "evidence_refs=#{inspect(Map.get(metadata, "evidence_refs", []))}"
    ])
  end

  defp render({:ok, {:drafts_list, drafts}}) do
    Render.ok(
      ["Self-improvement drafts: #{length(drafts)}"] ++
        Enum.map(drafts, fn draft ->
          "- #{draft.id} #{draft.kind} #{draft.tier} #{draft.artifact_path || ""}"
        end)
    )
  end

  defp render({:ok, {:drafts_inspect, draft}}) do
    Render.ok([
      "id=#{draft.id}",
      "kind=#{draft.kind}",
      "tier=#{draft.tier}",
      "live_authority=#{draft.live_authority}",
      "source_suggestion_id=#{draft.source_suggestion_id || "none"}",
      "artifact_path=#{draft.artifact_path || "none"}"
    ])
  end

  defp render({:ok, {:drafts_discard, draft}}) do
    Render.ok([
      "Discarded self-improvement draft #{draft.id}.",
      "tier=#{draft.tier}"
    ])
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, :invalid_list_args}), do: Render.error("Invalid list arguments.")

  defp render({:error, :invalid_drafts_list_args}),
    do: Render.error("Invalid drafts list arguments.")

  defp render({:error, :not_found}), do: Render.error("Suggestion not found.")

  defp render({:error, reason}),
    do: Render.error("Self-improvement command failed: #{inspect(reason)}")

  defp filter_kind(suggestions, nil), do: suggestions

  defp filter_kind(suggestions, kind) do
    Enum.filter(suggestions, &(&1.suggestion_type == kind))
  end
end
