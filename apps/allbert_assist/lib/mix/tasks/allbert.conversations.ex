defmodule Mix.Tasks.Allbert.Conversations do
  @moduledoc """
  Inspect and resume canonical Allbert conversations.

  ## Usage

      mix allbert.conversations show THREAD_ID [--user USER] [--limit 50]
      mix allbert.conversations resume THREAD_ID --channel CHANNEL --user USER --receiver RECEIVER --external-user EXTERNAL --provider-thread-key KEY
      mix allbert.conversations resume THREAD_ID --channel cli --user USER
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations.UnifiedHistory

  @shortdoc "Inspect and resume canonical Allbert conversations"

  @switches [
    channel: :string,
    external_user: :string,
    limit: :integer,
    provider_thread_key: :string,
    provider_thread_ref: :string,
    receiver: :string,
    user: :string
  ]

  @aliases [
    c: :channel,
    l: :limit,
    r: :receiver,
    u: :user
  ]

  @default_user "local"
  @default_limit 50

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    dispatch(args)
  end

  defp dispatch(["show", thread_id | rest]) do
    {opts, args, invalid} = OptionParser.parse(rest, switches: @switches, aliases: @aliases)
    reject_invalid!(invalid)
    reject_args!(args)

    case UnifiedHistory.show_thread(user!(opts), thread_id, limit: limit(opts[:limit])) do
      {:ok, history} -> print_history(history)
      {:error, {:thread_not_found, _id}} -> Mix.raise("Thread not found")
      {:error, reason} -> Mix.raise("Could not show conversation: #{inspect(reason)}")
    end
  end

  defp dispatch(["resume", thread_id | rest]) do
    {opts, args, invalid} = OptionParser.parse(rest, switches: @switches, aliases: @aliases)
    reject_invalid!(invalid)
    reject_args!(args)

    params =
      %{
        thread_id: thread_id,
        user_id: user!(opts),
        channel: required!(opts, :channel),
        receiver_account_ref: opts[:receiver],
        external_user_id: opts[:external_user],
        provider_thread_key: opts[:provider_thread_key],
        provider_thread_ref: opts[:provider_thread_ref]
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case Runner.run("resume_thread_on_channel", params, cli_context()) do
      {:ok, %{status: :completed, resume: resume} = response} ->
        Mix.shell().info(response.message)
        Mix.shell().info("Receiver: #{resume.receiver_account_ref}")
        Mix.shell().info("Provider thread key: #{resume.provider_thread_key}")
        Mix.shell().info("Continuity: #{resume.continuity.mode}")

      {:ok, response} ->
        Mix.raise(Map.get(response, :message, inspect(response)))
    end
  end

  defp dispatch(["show"]), do: Mix.raise("show requires THREAD_ID")
  defp dispatch(["resume"]), do: Mix.raise("resume requires THREAD_ID")

  defp dispatch(_args) do
    Mix.raise("Usage: mix allbert.conversations show|resume THREAD_ID [options]")
  end

  defp print_history(history) do
    Mix.shell().info("Thread: #{history.thread.id}")
    Mix.shell().info("User: #{history.thread.user_id}")
    Mix.shell().info("Ordering: #{history.ordering}")
    Mix.shell().info("Redaction: #{history.redaction}")
    Mix.shell().info("")

    if history.channels == [] do
      Mix.shell().info("Channels: none")
    else
      Mix.shell().info("Channels:")

      Enum.each(history.channels, fn channel ->
        Mix.shell().info(
          "- #{channel.channel} receiver=#{channel.receiver_account_ref} messages=#{channel.message_ref_count} thread_refs=#{channel.thread_ref_count}"
        )
      end)
    end

    Mix.shell().info("")
    Mix.shell().info("Messages:")
    Enum.each(history.messages, &print_message/1)
  end

  defp print_message(message) do
    Mix.shell().info("[#{time_text(message.inserted_at)}] #{message.role}: #{message.content}")

    Enum.each(message.channel_refs, fn ref ->
      Mix.shell().info(
        "  #{ref.direction} #{ref.channel}/#{ref.receiver_account_ref} message=#{ref.provider_message_id} part=#{ref.part_id}"
      )
    end)
  end

  defp cli_context do
    %{surface: :cli, source: :operator_cli}
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

  defp reject_args!([]), do: :ok
  defp reject_args!(args), do: Mix.raise("Unexpected argument(s): #{Enum.join(args, " ")}")

  defp user!(opts), do: blank_to_nil(opts[:user]) || @default_user

  defp required!(opts, key) do
    blank_to_nil(opts[key]) ||
      Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
  end

  defp limit(nil), do: @default_limit
  defp limit(value) when is_integer(value) and value > 0, do: min(value, 200)
  defp limit(_value), do: Mix.raise("--limit must be a positive integer")

  defp time_text(nil), do: "open"
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
