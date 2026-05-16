defmodule Mix.Tasks.Allbert.Memory do
  @moduledoc """
  Inspect and review Allbert markdown memory.

  ## Usage

      mix allbert.memory list [--category notes] [--status unreviewed] [--limit 20]
      mix allbert.memory show PATH
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

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.memory list [--category notes|preferences|traces|skills] [--status unreviewed|kept|flagged|prune_nominated] [--limit N] [--since YYYY-MM-DD] [--user USER]
      mix allbert.memory show PATH [--user USER]
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

  defp print_result({:error, reason}) do
    Mix.raise("Memory command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params, user_id) do
    case Runner.run(action_name, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
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
