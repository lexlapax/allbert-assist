defmodule Mix.Tasks.Stocksage.Queue do
  @moduledoc """
  Manage local StockSage queue rows.

      mix stocksage.queue create SYMBOL [--user USER] [--operator USER] [--thread-id THREAD_ID]
      mix stocksage.queue list [--user USER] [--operator USER] [--status STATUS]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Create and inspect local StockSage queue rows"
  @switches [
    user: :string,
    operator: :string,
    thread_id: :string,
    session_id: :string,
    status: :string,
    priority: :string,
    requested_for: :string,
    limit: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["create", symbol | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <-
           run_action(
             "queue_analysis",
             %{
               user_id: user_id,
               symbol: symbol,
               thread_id: Keyword.get(opts, :thread_id),
               session_id: Keyword.get(opts, :session_id),
               priority: Keyword.get(opts, :priority, "normal"),
               requested_for: Keyword.get(opts, :requested_for)
             },
             user_id
           ) do
      {:ok, {:created, response.queue_entry}}
    end
  end

  defp dispatch(["list" | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <-
           run_action(
             "list_queue",
             %{
               user_id: user_id,
               status: Keyword.get(opts, :status),
               limit: Keyword.get(opts, :limit, 50)
             },
             user_id
           ) do
      {:ok, {:list, user_id, response.queue_entries}}
    end
  end

  defp dispatch(_args), do: {:error, :usage}

  defp run_action(action, params, user_id) do
    case Runner.run(action, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, Map.get(response, :error, :action_failed)}
    end
  end

  defp context(user_id) do
    %{request: %{channel: :cli, user_id: user_id, operator_id: user_id, app_id: :stocksage}}
  end

  defp print_result({:ok, {:created, entry}}) do
    Mix.shell().info("StockSage queue entry #{entry.id}")
    Mix.shell().info("User: #{entry.user_id}")
    Mix.shell().info("Symbol: #{entry.symbol}")
    Mix.shell().info("Status: #{entry.status}")
    Mix.shell().info("Priority: #{entry.priority}")
    Mix.shell().info("Requested for: #{format_value(entry.requested_for)}")
    Mix.shell().info("Inserted at: #{format_value(entry.inserted_at)}")
  end

  defp print_result({:ok, {:list, user_id, entries}}) do
    Mix.shell().info("StockSage queue for #{user_id}")
    Mix.shell().info("Returned: #{length(entries)}")

    Enum.each(entries, fn entry ->
      Mix.shell().info(
        "#{entry.id} #{entry.symbol} status=#{entry.status} priority=#{entry.priority} requested_for=#{format_value(entry.requested_for)} analysis_id=#{format_value(entry.analysis_id)} updated_at=#{format_value(entry.updated_at)}"
      )
    end)
  end

  defp print_result({:error, reason}), do: Mix.raise(format_reason(reason))

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:invalid_options, invalid}}

  defp resolve_user(opts) do
    user = normalize_user(Keyword.get(opts, :user))
    operator = normalize_user(Keyword.get(opts, :operator))

    cond do
      user && operator && user != operator -> {:error, {:user_operator_mismatch, user, operator}}
      user -> {:ok, user}
      operator -> {:ok, operator}
      true -> {:ok, "local"}
    end
  end

  defp normalize_user(nil), do: nil

  defp normalize_user(user) when is_binary(user) do
    case String.trim(user) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp format_reason(:usage) do
    """
    Usage:
      mix stocksage.queue create SYMBOL [--user USER] [--operator USER] [--thread-id THREAD_ID]
      mix stocksage.queue list [--user USER] [--operator USER] [--status STATUS]
    """
  end

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"
  defp format_reason({:invalid_queue_entry, errors}), do: "invalid queue entry #{inspect(errors)}"
  defp format_reason(:action_failed), do: "StockSage queue action failed"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"

  defp format_reason(reason), do: inspect(reason)

  defp format_value(nil), do: "-"
  defp format_value(value), do: to_string(value)
end
