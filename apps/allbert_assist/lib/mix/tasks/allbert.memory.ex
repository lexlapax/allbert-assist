defmodule Mix.Tasks.Allbert.Memory do
  @moduledoc """
  Inspect and review Allbert markdown memory.

  ## Usage

      mix allbert.memory list [--category notes] [--status unreviewed] [--limit 20]
      mix allbert.memory show PATH
      mix allbert.memory review PATH --status kept|flagged|prune_nominated [--note "..."]
      mix allbert.memory update PATH [--summary "..."] [--body "..."] [--note "..."]
      mix allbert.memory delete PATH
      mix allbert.memory prune [--dry-run] [--write]
      mix allbert.memory search QUERY [--category notes] [--limit 10]
      mix allbert.memory compile-index
      mix allbert.memory summarize --category notes
      mix allbert.memory promote-turn --thread-id THREAD --message-id MESSAGE [--category notes]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect Allbert markdown memory"

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
        strict: [
          category: :string,
          status: :string,
          limit: :integer,
          since: :string,
          user: :string,
          operator: :string
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "list")
    user_id = user_id!(opts)

    params =
      %{
        user_id: user_id,
        category: opts[:category],
        review_status: opts[:status],
        limit: opts[:limit],
        since: opts[:since]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, response} <- completed_action("list_memory_entries", params, user_id) do
      {:ok, {:list, response.entries}}
    end
  end

  defp dispatch(["show", path | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "show")
    user_id = user_id!(opts)

    with {:ok, response} <-
           completed_action("read_memory_entry", %{path: path, user_id: user_id}, user_id) do
      {:ok, {:entry, response.entry}}
    end
  end

  defp dispatch(["review", path | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [status: :string, note: :string, user: :string, operator: :string]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "review")
    user_id = user_id!(opts)
    status = opts[:status] || Mix.raise("review requires --status")

    params = %{path: path, status: status, note: opts[:note], user_id: user_id}

    with {:ok, response} <- completed_action("review_memory_entry", params, user_id) do
      {:ok, {:reviewed, response.entry}}
    end
  end

  defp dispatch(["update", path | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [summary: :string, body: :string, note: :string, user: :string, operator: :string]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "update")
    user_id = user_id!(opts)

    params =
      %{
        path: path,
        summary: opts[:summary],
        body: opts[:body],
        note: opts[:note],
        user_id: user_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, response} <- completed_action("update_memory_entry", params, user_id) do
      {:ok, {:updated, response.entry}}
    end
  end

  defp dispatch(["delete", path | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "delete")
    user_id = user_id!(opts)

    with {:ok, response} <-
           accepted_action("delete_memory_entry", %{path: path, user_id: user_id}, user_id) do
      {:ok, {:delete, response}}
    end
  end

  defp dispatch(["prune" | args]) do
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

    reject_invalid!(invalid)
    reject_rest!(rest, "prune")
    user_id = user_id!(opts)

    params =
      %{
        category: opts[:category],
        write: opts[:write] == true,
        user_id: user_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, response} <- accepted_action("prune_memory_entries", params, user_id) do
      {:ok, {:prune, response}}
    end
  end

  defp dispatch(["search", query | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [category: :string, limit: :integer, user: :string, operator: :string]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "search")
    user_id = user_id!(opts)

    params =
      %{query: query, category: opts[:category], limit: opts[:limit], user_id: user_id}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, response} <- completed_action("search_memory", params, user_id) do
      {:ok, {:search, response.entries}}
    end
  end

  defp dispatch(["compile-index" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "compile-index")
    user_id = user_id!(opts)

    with {:ok, response} <- completed_action("compile_memory_index", %{user_id: user_id}, user_id) do
      {:ok, {:compiled_index, response.result}}
    end
  end

  defp dispatch(["summarize" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [category: :string, user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "summarize")
    user_id = user_id!(opts)
    category = opts[:category] || Mix.raise("summarize requires --category")

    with {:ok, response} <-
           completed_action(
             "summarize_memory_category",
             %{category: category, user_id: user_id},
             user_id
           ) do
      {:ok, {:summary, response.result}}
    end
  end

  defp dispatch(["promote-turn" | args]) do
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

    reject_invalid!(invalid)
    reject_rest!(rest, "promote-turn")
    user_id = user_id!(opts)

    params =
      %{
        user_id: user_id,
        thread_id: opts[:thread_id] || Mix.raise("promote-turn requires --thread-id"),
        message_id: opts[:message_id] || Mix.raise("promote-turn requires --message-id"),
        category: opts[:category],
        summary: opts[:summary]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, response} <- accepted_action("promote_conversation_turn", params, user_id) do
      {:ok, {:promote_turn, response}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.memory list [--category notes|preferences|traces|skills] [--status unreviewed|kept|flagged|prune_nominated] [--limit N] [--since YYYY-MM-DD] [--user USER]
      mix allbert.memory show PATH [--user USER]
      mix allbert.memory review PATH --status kept|flagged|prune_nominated [--note "..."] [--user USER]
      mix allbert.memory update PATH [--summary "..."] [--body "..."] [--note "..."] [--user USER]
      mix allbert.memory delete PATH [--user USER]
      mix allbert.memory prune [--category notes|preferences|traces|skills] [--dry-run] [--write] [--user USER]
      mix allbert.memory search QUERY [--category notes|preferences|traces|skills] [--limit N] [--user USER]
      mix allbert.memory compile-index [--user USER]
      mix allbert.memory summarize --category notes|preferences|traces|skills [--user USER]
      mix allbert.memory promote-turn --thread-id THREAD_ID --message-id MESSAGE_ID [--category notes] [--summary "..."] [--user USER]
    """)
  end

  defp print_result({:ok, {:list, []}}) do
    Mix.shell().info("No memory entries.")
  end

  defp print_result({:ok, {:list, entries}}) do
    Enum.each(entries, fn entry ->
      Mix.shell().info(
        "#{entry.timestamp} #{entry.category} #{entry.review_status} #{entry.summary} #{entry.path}"
      )
    end)
  end

  defp print_result({:ok, {:entry, entry}}) do
    Mix.shell().info("Path: #{entry.path}")
    Mix.shell().info("Category: #{entry.category}")
    Mix.shell().info("Timestamp: #{entry.timestamp}")
    Mix.shell().info("Actor: #{entry.actor}")
    Mix.shell().info("Review status: #{entry.review_status}")

    if entry.reviewed_at do
      Mix.shell().info("Reviewed: #{entry.reviewed_at}")
      Mix.shell().info("Reviewed by: #{entry.reviewed_by}")
      Mix.shell().info("Correction note: #{entry.correction_note}")
    end

    Mix.shell().info("")
    Mix.shell().info(entry.body)
  end

  defp print_result({:ok, {label, entry}}) when label in [:reviewed, :updated] do
    Mix.shell().info("#{label}: #{entry.path}")
    Mix.shell().info("Summary: #{entry.summary}")
    Mix.shell().info("Review status: #{entry.review_status}")
  end

  defp print_result({:ok, {:delete, %{status: :needs_confirmation} = response}}) do
    Mix.shell().info("Confirmation: #{response.confirmation_id}")
    Mix.shell().info("No file was moved.")
  end

  defp print_result({:ok, {:delete, %{status: :completed} = response}}) do
    Mix.shell().info("Archived: #{response.archived.path}")
    Mix.shell().info("Archived path: #{response.archived.archived_path}")
  end

  defp print_result({:ok, {:prune, %{status: :needs_confirmation} = response}}) do
    Mix.shell().info("Confirmation: #{response.confirmation_id}")
    Mix.shell().info("Candidate count: #{length(response.candidates)}")
  end

  defp print_result({:ok, {:prune, response}}) do
    Mix.shell().info("Candidate count: #{length(response.candidates)}")

    Enum.each(response.candidates, fn candidate ->
      Mix.shell().info(
        "#{candidate.reason} #{candidate.category} #{candidate.summary} #{candidate.path}"
      )
    end)
  end

  defp print_result({:ok, {:search, []}}) do
    Mix.shell().info("No memory search results.")
  end

  defp print_result({:ok, {:search, entries}}) do
    Enum.each(entries, fn entry ->
      Mix.shell().info(
        "#{entry.score} #{entry.category} #{entry.review_status} #{entry.summary} #{entry.path}"
      )
    end)
  end

  defp print_result({:ok, {:compiled_index, result}}) do
    Mix.shell().info("Index: #{result.path}")
    Mix.shell().info("Entries: #{result.entry_count}")
    Mix.shell().info("Elapsed ms: #{result.elapsed_ms}")
  end

  defp print_result({:ok, {:summary, result}}) do
    Mix.shell().info("Summary: #{result.path}")
    Mix.shell().info("Entries: #{result.entry_count}")
    Mix.shell().info("Derived at: #{result.derived_at}")
  end

  defp print_result({:ok, {:promote_turn, %{status: :needs_confirmation} = response}}) do
    Mix.shell().info("Confirmation: #{response.confirmation_id}")
    Mix.shell().info("No memory was written.")
  end

  defp print_result({:ok, {:promote_turn, %{status: :completed} = response}}) do
    Mix.shell().info("Promoted: #{response.memory.path}")
    Mix.shell().info("Summary: #{response.memory.summary}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Memory command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params, user_id) do
    case Runner.run(action_name, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp accepted_action(action_name, params, user_id) do
    case Runner.run(action_name, params, context(user_id)) do
      {:ok, %{status: status} = response} when status in [:completed, :needs_confirmation] ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message
  defp response_error(response), do: response

  defp context(user_id) do
    %{actor: user_id, user_id: user_id, operator_id: user_id, channel: :cli}
  end

  defp user_id!(opts) do
    user = opts[:user]
    operator = opts[:operator]

    cond do
      present?(user) and present?(operator) and user != operator ->
        Mix.raise("--user and --operator must match when both are provided.")

      present?(user) ->
        user

      present?(operator) ->
        operator

      true ->
        "local"
    end
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Unknown options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: Mix.raise("Unexpected #{command} arguments: #{inspect(rest)}")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
