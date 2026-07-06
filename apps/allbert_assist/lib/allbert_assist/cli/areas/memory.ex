defmodule AllbertAssist.CLI.Areas.Memory do
  @moduledoc """
  Release-safe `memory` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.memory` and `allbert admin memory`:
  `dispatch/2` parses the sub-argv, routes to the same registered actions the
  Mix task used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls,
  so it runs inside the packaged release. `Mix.Tasks.Allbert.Memory` is a thin
  wrapper that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    mix allbert.memory list [--category notes|preferences|traces|skills|identity] [--namespace identity] [--status unreviewed|kept|flagged|prune_nominated] [--limit N] [--since YYYY-MM-DD] [--user USER]
    mix allbert.memory show PATH [--user USER]
    mix allbert.memory review PATH --status kept|flagged|prune_nominated [--note "..."] [--user USER]
    mix allbert.memory update PATH [--summary "..."] [--body "..."] [--note "..."] [--user USER]
    mix allbert.memory delete PATH [--user USER]
    mix allbert.memory prune [--category notes|preferences|traces|skills|identity] [--dry-run] [--write] [--user USER]
    mix allbert.memory search QUERY [--category notes|preferences|traces|skills|identity] [--limit N] [--user USER]
    mix allbert.memory retrieve --query "..." [--thread-id THREAD_ID] [--active-app APP_ID] [--identity-namespace identity] [--now ISO8601] [--user USER]
    mix allbert.memory compile-index [--user USER]
    mix allbert.memory summarize --category notes|preferences|traces|skills|identity [--user USER]
    mix allbert.memory promote-turn --thread-id THREAD_ID --message-id MESSAGE_ID [--category notes] [--summary "..."] [--user USER]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin memory")

  # -- routing ---------------------------------------------------------------

  defp route([], ctx), do: route(["list"], ctx)

  defp route(["list" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          category: :string,
          namespace: :string,
          status: :string,
          limit: :integer,
          since: :string,
          user: :string,
          operator: :string
        ]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "list"),
         {:ok, user_id} <- resolve_user_id(opts),
         params =
           %{
             user_id: user_id,
             category: opts[:category],
             namespace: opts[:namespace],
             review_status: opts[:status],
             limit: opts[:limit],
             since: opts[:since]
           }
           |> compact(),
         {:ok, response} <- completed_action("list_memory_entries", params, ctx, user_id) do
      {:ok, {:list, response.entries}}
    end
  end

  defp route(["show", path | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "show"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, response} <-
           completed_action("read_memory_entry", %{path: path, user_id: user_id}, ctx, user_id) do
      {:ok, {:entry, response.entry}}
    end
  end

  defp route(["review", path | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [status: :string, note: :string, user: :string, operator: :string]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "review"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, status} <- require_value(opts[:status], "review requires --status"),
         params = %{path: path, status: status, note: opts[:note], user_id: user_id},
         {:ok, response} <- completed_action("review_memory_entry", params, ctx, user_id) do
      {:ok, {:reviewed, response.entry}}
    end
  end

  defp route(["update", path | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [summary: :string, body: :string, note: :string, user: :string, operator: :string]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "update"),
         {:ok, user_id} <- resolve_user_id(opts),
         params =
           %{
             path: path,
             summary: opts[:summary],
             body: opts[:body],
             note: opts[:note],
             user_id: user_id
           }
           |> compact(),
         {:ok, response} <- completed_action("update_memory_entry", params, ctx, user_id) do
      {:ok, {:updated, response.entry}}
    end
  end

  defp route(["delete", path | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "delete"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, response} <-
           accepted_action("delete_memory_entry", %{path: path, user_id: user_id}, ctx, user_id) do
      {:ok, {:delete, response}}
    end
  end

  defp route(["prune" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          category: :string,
          dry_run: :boolean,
          write: :boolean,
          user: :string,
          operator: :string
        ]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "prune"),
         {:ok, user_id} <- resolve_user_id(opts),
         params =
           %{
             category: opts[:category],
             write: opts[:write] == true,
             user_id: user_id
           }
           |> compact(),
         {:ok, response} <- accepted_action("prune_memory_entries", params, ctx, user_id) do
      {:ok, {:prune, response}}
    end
  end

  defp route(["search", query | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [category: :string, limit: :integer, user: :string, operator: :string]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "search"),
         {:ok, user_id} <- resolve_user_id(opts),
         params =
           %{query: query, category: opts[:category], limit: opts[:limit], user_id: user_id}
           |> compact(),
         {:ok, response} <- completed_action("search_memory", params, ctx, user_id) do
      {:ok, {:search, response.entries}}
    end
  end

  defp route(["retrieve" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          query: :string,
          user: :string,
          operator: :string,
          thread_id: :string,
          active_app: :string,
          identity_namespace: :string,
          now: :string
        ]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "retrieve"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, query} <- require_value(opts[:query], "retrieve requires --query"),
         params =
           %{
             query: query,
             user_id: user_id,
             thread_id: opts[:thread_id],
             active_app: opts[:active_app],
             identity_namespace: opts[:identity_namespace],
             now: opts[:now]
           }
           |> compact(),
         {:ok, response} <- completed_action("retrieve_active_memory", params, ctx, user_id) do
      {:ok, {:retrieve, response.active_memory}}
    end
  end

  defp route(["compile-index" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "compile-index"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, response} <-
           completed_action("compile_memory_index", %{user_id: user_id}, ctx, user_id) do
      {:ok, {:compiled_index, response.result}}
    end
  end

  defp route(["summarize" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [category: :string, user: :string, operator: :string])

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "summarize"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, category} <- require_value(opts[:category], "summarize requires --category"),
         {:ok, response} <-
           completed_action(
             "summarize_memory_category",
             %{category: category, user_id: user_id},
             ctx,
             user_id
           ) do
      {:ok, {:summary, response.result}}
    end
  end

  defp route(["promote-turn" | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          thread_id: :string,
          message_id: :string,
          category: :string,
          summary: :string,
          user: :string,
          operator: :string
        ]
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_rest(rest, "promote-turn"),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, thread_id} <- require_value(opts[:thread_id], "promote-turn requires --thread-id"),
         {:ok, message_id} <-
           require_value(opts[:message_id], "promote-turn requires --message-id"),
         params =
           %{
             user_id: user_id,
             thread_id: thread_id,
             message_id: message_id,
             category: opts[:category],
             summary: opts[:summary]
           }
           |> compact(),
         {:ok, response} <- accepted_action("promote_conversation_turn", params, ctx, user_id) do
      {:ok, {:promote_turn, response}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # -- rendering -------------------------------------------------------------

  defp render({:ok, {:list, []}}), do: Render.ok("No memory entries.")

  defp render({:ok, {:list, entries}}) do
    Render.ok(
      Enum.map(entries, fn entry ->
        "#{entry.timestamp} #{entry.category} #{entry.review_status} #{entry.summary} #{entry.path}"
      end)
    )
  end

  defp render({:ok, {:entry, entry}}) do
    base = [
      "Path: #{entry.path}",
      "Category: #{entry.category}",
      "Timestamp: #{entry.timestamp}",
      "Actor: #{entry.actor}",
      "Review status: #{entry.review_status}"
    ]

    reviewed =
      if entry.reviewed_at do
        [
          "Reviewed: #{entry.reviewed_at}",
          "Reviewed by: #{entry.reviewed_by}",
          "Correction note: #{entry.correction_note}"
        ]
      else
        []
      end

    Render.ok(base ++ reviewed ++ ["", entry.body])
  end

  defp render({:ok, {label, entry}}) when label in [:reviewed, :updated] do
    Render.ok([
      "#{label}: #{entry.path}",
      "Summary: #{entry.summary}",
      "Review status: #{entry.review_status}"
    ])
  end

  defp render({:ok, {:delete, %{status: :needs_confirmation} = response}}) do
    Render.ok([
      "Confirmation: #{response.confirmation_id}",
      "No file was moved."
    ])
  end

  defp render({:ok, {:delete, %{status: :completed} = response}}) do
    Render.ok([
      "Archived: #{response.archived.path}",
      "Archived path: #{response.archived.archived_path}"
    ])
  end

  defp render({:ok, {:prune, %{status: :needs_confirmation} = response}}) do
    Render.ok([
      "Confirmation: #{response.confirmation_id}",
      "Candidate count: #{length(response.candidates)}"
    ])
  end

  defp render({:ok, {:prune, response}}) do
    Render.ok(
      ["Candidate count: #{length(response.candidates)}"] ++
        Enum.map(response.candidates, fn candidate ->
          "#{candidate.reason} #{candidate.category} #{candidate.summary} #{candidate.path}"
        end)
    )
  end

  defp render({:ok, {:search, []}}), do: Render.ok("No memory search results.")

  defp render({:ok, {:search, entries}}) do
    Render.ok(
      Enum.map(entries, fn entry ->
        "#{entry.score} #{entry.category} #{entry.review_status} #{entry.summary} #{entry.path}"
      end)
    )
  end

  defp render({:ok, {:retrieve, active_memory}}) do
    base = [
      "Active Memory chunks: #{length(Map.get(active_memory, :retrieved_chunks, []))}",
      "Status: #{Map.get(active_memory, :status, :unknown)}",
      "Enabled: #{Map.get(active_memory, :enabled?, :unknown)}",
      "Terms: #{retrieve_terms(active_memory)}",
      "Scope: #{inspect(Map.get(active_memory, :scope, %{}), pretty: true)}",
      "Candidate chunks before filter: #{Map.get(active_memory, :candidate_chunk_count_before_filter, 0)}",
      "Candidate chunks after filter: #{Map.get(active_memory, :candidate_count_after_filter, 0)}"
    ]

    chunk_lines =
      active_memory
      |> Map.get(:retrieved_chunks, [])
      |> case do
        [] -> ["No Active Memory chunks retrieved."]
        chunks -> Enum.flat_map(chunks, &retrieved_chunk_lines/1)
      end

    Render.ok(base ++ chunk_lines)
  end

  defp render({:ok, {:compiled_index, result}}) do
    Render.ok([
      "Index: #{result.path}",
      "Entries: #{result.entry_count}",
      "Elapsed ms: #{result.elapsed_ms}"
    ])
  end

  defp render({:ok, {:summary, result}}) do
    Render.ok([
      "Summary: #{result.path}",
      "Entries: #{result.entry_count}",
      "Derived at: #{result.derived_at}"
    ])
  end

  defp render({:ok, {:promote_turn, %{status: :needs_confirmation} = response}}) do
    Render.ok([
      "Confirmation: #{response.confirmation_id}",
      "No memory was written."
    ])
  end

  defp render({:ok, {:promote_turn, %{status: :completed} = response}}) do
    Render.ok([
      "Promoted: #{response.memory.path}",
      "Summary: #{response.memory.summary}"
    ])
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:arg, message}}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("Memory command failed: #{inspect(reason)}")

  # -- action + read helpers -------------------------------------------------

  defp completed_action(action_name, params, ctx, user_id) do
    ActionHelper.completed_action(action_name, params, context(ctx, user_id))
  end

  defp accepted_action(action_name, params, ctx, user_id) do
    case Runner.run(action_name, params, context(ctx, user_id)) do
      {:ok, %{status: status} = response} when status in [:completed, :needs_confirmation] ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp context(ctx, user_id) do
    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: surface(ctx)
    )
  end

  defp surface(ctx), do: Map.get(ctx, :surface) || "allbert admin memory"

  defp retrieve_terms(active_memory) do
    active_memory
    |> Map.get(:query_terms_normalized, [])
    |> case do
      [] -> "none"
      terms -> Enum.join(terms, ", ")
    end
  end

  defp retrieved_chunk_lines(chunk) do
    [
      "#{chunk.chunk_id} score=#{chunk.score} recency=#{chunk.recency_decay} thread=#{chunk.thread_affinity} identity=#{chunk.identity_inclusion} lexical=#{chunk.lexical_match}",
      "  #{chunk.category} namespace=#{chunk.namespace || "none"} #{chunk.summary} #{chunk.entry_path}"
    ]
  end

  # -- argument parsing helpers ----------------------------------------------

  defp resolve_user_id(opts) do
    user = opts[:user]
    operator = opts[:operator]

    cond do
      present?(user) and present?(operator) and user != operator ->
        {:error, {:arg, "--user and --operator must match when both are provided."}}

      present?(user) ->
        {:ok, user}

      present?(operator) ->
        {:ok, operator}

      true ->
        {:ok, "local"}
    end
  end

  defp require_value(nil, message), do: {:error, {:arg, message}}
  defp require_value(value, _message), do: {:ok, value}

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:arg, "Unknown options: #{inspect(invalid)}"}}

  defp reject_rest([], _command), do: :ok

  defp reject_rest(rest, command),
    do: {:error, {:arg, "Unexpected #{command} arguments: #{inspect(rest)}"}}

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
