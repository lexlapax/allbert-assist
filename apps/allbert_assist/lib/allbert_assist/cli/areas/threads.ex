defmodule AllbertAssist.CLI.Areas.Threads do
  @moduledoc """
  Release-safe `threads` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.threads`,
  `mix allbert.conversations`, and `allbert admin threads`: `dispatch/2` parses
  the sub-argv and owns the union of both tasks' subcommands (thread listing +
  `complete` from `allbert.threads`; canonical `show`/`resume` from
  `allbert.conversations`). It routes to the same reads and actions the Mix tasks
  used and returns `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs
  inside the packaged release. Both Mix tasks are thin wrappers that print the
  output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Surfaces.ContextBuilder

  @thread_switches [
    user: :string,
    operator: :string,
    thread: :string,
    limit: :integer
  ]

  @thread_aliases [
    u: :user,
    o: :operator,
    t: :thread
  ]

  @conversation_switches [
    channel: :string,
    external_user: :string,
    include_e2ee_origin: :boolean,
    limit: :integer,
    provider_thread_key: :string,
    provider_thread_ref: :string,
    receiver: :string,
    user: :string
  ]

  @conversation_aliases [
    c: :channel,
    l: :limit,
    r: :receiver,
    u: :user
  ]

  @default_user "local"
  @default_thread_limit 20
  @default_conversation_limit 50

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin threads")

  # -- routing ---------------------------------------------------------------

  # allbert.threads: complete a thread.
  defp route(["complete", thread_id | args], ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        switches: [user: :string, operator: :string],
        aliases: @thread_aliases
      )

    with :ok <- reject_invalid(invalid),
         :ok <- reject_extra(rest),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, thread} <- complete_thread(user_id, thread_id, ctx) do
      {:ok, {:completed, thread}}
    end
  end

  defp route(["complete"], _ctx), do: {:error, {:arg, "complete requires THREAD_ID"}}

  # allbert.conversations: canonical unified history.
  defp route(["show", thread_id | rest], _ctx) do
    {opts, args, invalid} =
      OptionParser.parse(rest, switches: @conversation_switches, aliases: @conversation_aliases)

    with :ok <- reject_invalid(invalid),
         :ok <- reject_extra(args),
         {:ok, limit} <- conversation_limit(opts[:limit]),
         user_id = conversation_user(opts),
         history_opts = [
           limit: limit,
           include_e2ee_origin: opts[:include_e2ee_origin],
           viewer_channel: "cli",
           audit_context: %{actor: user_id, channel: "cli"}
         ],
         {:ok, history} <- show_history(user_id, thread_id, history_opts) do
      {:ok, {:history, history}}
    end
  end

  defp route(["show"], _ctx), do: {:error, {:arg, "show requires THREAD_ID"}}

  # allbert.conversations: resume a canonical thread on a channel.
  defp route(["resume", thread_id | rest], ctx) do
    {opts, args, invalid} =
      OptionParser.parse(rest, switches: @conversation_switches, aliases: @conversation_aliases)

    with :ok <- reject_invalid(invalid),
         :ok <- reject_extra(args),
         user_id = conversation_user(opts),
         {:ok, channel} <- required(opts, :channel),
         params =
           %{
             thread_id: thread_id,
             user_id: user_id,
             channel: channel,
             receiver_account_ref: opts[:receiver],
             external_user_id: opts[:external_user],
             provider_thread_key: opts[:provider_thread_key],
             provider_thread_ref: opts[:provider_thread_ref]
           }
           |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
           |> Map.new(),
         {:ok, resumed} <- resume_thread(params, user_id, ctx) do
      {:ok, {:resume, resumed}}
    end
  end

  defp route(["resume"], _ctx), do: {:error, {:arg, "resume requires THREAD_ID"}}

  # allbert.threads: list threads, or show a single thread with --thread.
  defp route(args, _ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, switches: @thread_switches, aliases: @thread_aliases)

    with :ok <- reject_invalid(invalid),
         :ok <- reject_extra(rest),
         {:ok, user_id} <- resolve_user_id(opts),
         {:ok, limit} <- thread_limit(opts[:limit]) do
      case blank_to_nil(opts[:thread]) do
        nil -> list_threads(user_id, limit)
        thread_id -> show_thread(user_id, thread_id, limit)
      end
    end
  end

  # -- rendering: threads listing / show ------------------------------------

  defp render({:ok, {:threads, []}}), do: Render.ok("No threads.")

  defp render({:ok, {:threads, threads}}) do
    Render.ok(
      Enum.map(threads, fn thread ->
        "#{thread.id} user=#{thread.user_id} kind=#{thread.kind} app=#{app_text(thread.app_id)} messages=#{Conversations.message_count(thread)} updated=#{time_text(thread.last_message_at)} completed=#{time_text(thread.completed_at)} title=#{thread.title}"
      end)
    )
  end

  defp render({:ok, {:thread, thread, messages}}) do
    header = [
      "Thread: #{thread.id}",
      "User: #{thread.user_id}",
      "Kind: #{thread.kind}",
      "App: #{app_text(thread.app_id)}",
      "Completed: #{time_text(thread.completed_at)}",
      ""
    ]

    Render.ok(header ++ Enum.map(messages, &thread_message_line/1))
  end

  defp render({:ok, {:completed, thread}}) do
    Render.ok([
      "Completed thread: #{thread.id}",
      "Completed at: #{time_text(thread.completed_at)}"
    ])
  end

  # -- rendering: conversations show / resume -------------------------------

  defp render({:ok, {:history, history}}) do
    header = [
      "Thread: #{history.thread.id}",
      "User: #{history.thread.user_id}",
      "Ordering: #{history.ordering}",
      "Redaction: #{history.redaction}",
      "E2EE-origin hidden: #{history.trust.filtered_e2ee_origin_count}",
      ""
    ]

    channels =
      if history.channels == [] do
        ["Channels: none"]
      else
        ["Channels:"] ++
          Enum.map(history.channels, fn channel ->
            "- #{channel.channel} receiver=#{channel.receiver_account_ref} trust=#{Enum.join(channel.trust_classes, ",")} messages=#{channel.message_ref_count} thread_refs=#{channel.thread_ref_count}"
          end)
      end

    messages = ["", "Messages:"] ++ Enum.flat_map(history.messages, &history_message_lines/1)

    Render.ok(header ++ channels ++ messages)
  end

  defp render({:ok, {:resume, {response, resume}}}) do
    Render.ok([
      response.message,
      "Receiver: #{resume.receiver_account_ref}",
      "Provider thread key: #{resume.provider_thread_key}",
      "Continuity: #{resume.continuity.mode}"
    ])
  end

  defp render({:error, {:arg, message}}), do: Render.error(message)

  defp thread_message_line(message) do
    "[#{time_text(message.inserted_at)}] #{message.role}: #{message.content}"
  end

  defp history_message_lines(message) do
    ["[#{time_text(message.inserted_at)}] #{message.role}: #{message.content}"] ++
      Enum.map(message.channel_refs, fn ref ->
        "  #{ref.direction} #{ref.channel}/#{ref.receiver_account_ref} trust=#{ref.trust_class} message=#{ref.provider_message_id} part=#{ref.part_id}"
      end)
  end

  # -- read + action helpers -------------------------------------------------

  defp list_threads(user_id, limit) do
    {:ok, {:threads, Conversations.list_threads(user_id, limit: limit)}}
  end

  defp show_thread(user_id, thread_id, limit) do
    case Conversations.show_thread(user_id, thread_id, limit: limit) do
      {:ok, %{thread: thread, messages: messages}} -> {:ok, {:thread, thread, messages}}
      {:error, {:thread_not_found, _id}} -> {:error, {:arg, "Thread not found"}}
    end
  end

  # Completion is a mutation: it rides the one spine through `Runner.run`, which
  # enforces the PermissionGate + audit around `Conversations.complete_thread/2`.
  # Identity is server-derived from the CLI context, not the caller's params.
  defp complete_thread(user_id, thread_id, ctx) do
    case Runner.run(
           "complete_thread",
           %{user_id: user_id, thread_id: thread_id},
           complete_context(ctx, user_id)
         ) do
      {:ok, %{status: :completed, thread: thread}} ->
        {:ok, thread}

      {:ok, %{status: :error, error: {:thread_not_found, _id}}} ->
        {:error, {:arg, "Thread not found"}}

      {:ok, response} ->
        {:error, {:arg, Map.get(response, :message) || "Thread completion failed"}}
    end
  end

  defp complete_context(ctx, user_id) do
    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: Map.get(ctx, :surface) || :cli,
      source: :operator_cli
    )
  end

  defp show_history(user_id, thread_id, history_opts) do
    case UnifiedHistory.show_thread(user_id, thread_id, history_opts) do
      {:ok, history} -> {:ok, history}
      {:error, {:thread_not_found, _id}} -> {:error, {:arg, "Thread not found"}}
    end
  end

  defp resume_thread(params, user_id, ctx) do
    case Runner.run("resume_thread_on_channel", params, resume_context(ctx, user_id)) do
      {:ok, %{status: :completed, resume: resume} = response} ->
        {:ok, {response, resume}}

      {:ok, response} ->
        {:error, {:arg, Map.get(response, :message, inspect(response))}}
    end
  end

  defp resume_context(ctx, user_id) do
    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: Map.get(ctx, :surface) || :cli,
      source: :operator_cli
    )
  end

  # -- argument parsing helpers ----------------------------------------------

  defp resolve_user_id(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        {:error, {:arg, "--user and --operator must match when both are provided"}}

      user ->
        {:ok, user}

      operator ->
        {:ok, operator}

      true ->
        {:ok, "local"}
    end
  end

  defp conversation_user(opts), do: blank_to_nil(opts[:user]) || @default_user

  defp required(opts, key) do
    case blank_to_nil(opts[key]) do
      nil -> {:error, {:arg, "--#{String.replace(to_string(key), "_", "-")} is required"}}
      value -> {:ok, value}
    end
  end

  defp thread_limit(nil), do: {:ok, @default_thread_limit}
  defp thread_limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, 100)}
  defp thread_limit(_value), do: {:error, {:arg, "--limit must be a positive integer"}}

  defp conversation_limit(nil), do: {:ok, @default_conversation_limit}
  defp conversation_limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, 200)}
  defp conversation_limit(_value), do: {:error, {:arg, "--limit must be a positive integer"}}

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:arg, "Invalid option(s): #{inspect(invalid)}"}}

  defp reject_extra([]), do: :ok

  defp reject_extra(args),
    do: {:error, {:arg, "Unexpected argument(s): #{Enum.join(args, " ")}"}}

  defp app_text(nil), do: "general"
  defp app_text(""), do: "general"
  defp app_text(app_id), do: app_id

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
