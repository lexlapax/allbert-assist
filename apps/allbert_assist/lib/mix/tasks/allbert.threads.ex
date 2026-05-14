defmodule Mix.Tasks.Allbert.Threads do
  @moduledoc """
  Inspect local Allbert conversation threads.

  ## Usage

      mix allbert.threads
      mix allbert.threads --user alice
      mix allbert.threads --user alice --thread THREAD_ID
      mix allbert.threads --operator alice --limit 5
  """

  use Mix.Task

  alias AllbertAssist.Conversations

  @shortdoc "Inspect local Allbert conversation threads"

  @switches [
    user: :string,
    operator: :string,
    thread: :string,
    limit: :integer
  ]

  @aliases [
    u: :user,
    o: :operator,
    t: :thread
  ]

  @default_limit 20

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    if rest != [] do
      Mix.raise("Unexpected argument(s): #{Enum.join(rest, " ")}")
    end

    user_id = user_id!(opts)
    limit = limit(opts[:limit])

    case blank_to_nil(opts[:thread]) do
      nil -> print_threads(user_id, limit)
      thread_id -> print_thread(user_id, thread_id, limit)
    end
  end

  defp print_threads(user_id, limit) do
    case Conversations.list_threads(user_id, limit: limit) do
      [] ->
        Mix.shell().info("No threads.")

      threads ->
        Enum.each(threads, fn thread ->
          Mix.shell().info(
            "#{thread.id} user=#{thread.user_id} kind=#{thread.kind} app=#{app_text(thread.app_id)} messages=#{Conversations.message_count(thread)} updated=#{time_text(thread.last_message_at)} title=#{thread.title}"
          )
        end)
    end
  end

  defp print_thread(user_id, thread_id, limit) do
    case Conversations.show_thread(user_id, thread_id, limit: limit) do
      {:ok, %{thread: thread, messages: messages}} ->
        Mix.shell().info("Thread: #{thread.id}")
        Mix.shell().info("User: #{thread.user_id}")
        Mix.shell().info("Kind: #{thread.kind}")
        Mix.shell().info("App: #{app_text(thread.app_id)}")
        Mix.shell().info("")
        Enum.each(messages, &print_message/1)

      {:error, {:thread_not_found, _id}} ->
        Mix.raise("Thread not found")

      {:error, reason} ->
        Mix.raise("Threads command failed: #{inspect(reason)}")
    end
  end

  defp print_message(message) do
    Mix.shell().info("[#{time_text(message.inserted_at)}] #{message.role}: #{message.content}")
  end

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        Mix.raise("--user and --operator must match when both are provided")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp limit(nil), do: @default_limit
  defp limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp limit(_value), do: Mix.raise("--limit must be a positive integer")

  defp app_text(nil), do: "general"
  defp app_text(""), do: "general"
  defp app_text(app_id), do: app_id

  defp time_text(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp time_text(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_iso8601(timestamp)
  defp time_text(timestamp), do: to_string(timestamp)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end
end
