defmodule AllbertAssist.CLI.Areas.Sessions do
  @moduledoc """
  Release-safe `sessions` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.sessions` and
  `allbert admin sessions`: `dispatch/2` parses the sub-argv, routes to the same
  actions and `Session` reads the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Sessions` is a thin wrapper that prints
  the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Session
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    mix allbert.sessions list [--user USER]
    mix allbert.sessions show --user USER --session SESSION_ID
    mix allbert.sessions set-active-app --user USER --session SESSION_ID APP
    mix allbert.sessions clear-active-app --user USER --session SESSION_ID
    mix allbert.sessions clear --user USER --session SESSION_ID
    mix allbert.sessions sweep
  """

  @switches [
    operator: :string,
    session: :string,
    user: :string
  ]

  @aliases [
    o: :operator,
    s: :session,
    u: :user
  ]

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin sessions")

  # -- routing ---------------------------------------------------------------

  defp route([], ctx), do: route(["list"], ctx)

  defp route(["list" | rest], _ctx) do
    {opts, [], invalid} = parse_opts(rest)

    with :ok <- reject_invalid(invalid),
         {:ok, identity} <- identity(opts),
         {:ok, entries} <- Session.list(identity.user_id) do
      {:ok, {:list, entries}}
    end
  end

  defp route(["show" | rest], _ctx) do
    {opts, [], invalid} = parse_opts(rest)

    with :ok <- reject_invalid(invalid),
         {:ok, identity} <- identity(opts),
         {:ok, session_id} <- session_id(opts) do
      run_action("show_session_scratchpad", %{user_id: identity.user_id, session_id: session_id})
    end
  end

  defp route(["set-active-app" | rest], _ctx) do
    {opts, args, invalid} = parse_opts(rest)

    with :ok <- reject_invalid(invalid),
         {:ok, identity} <- identity(opts),
         {:ok, session_id} <- session_id(opts),
         {:ok, app_id} <- single_arg(args, "APP is required") do
      run_action("set_active_app", %{
        user_id: identity.user_id,
        session_id: session_id,
        app_id: app_id
      })
    end
  end

  defp route(["clear-active-app" | rest], _ctx) do
    {opts, [], invalid} = parse_opts(rest)

    with :ok <- reject_invalid(invalid),
         {:ok, identity} <- identity(opts),
         {:ok, session_id} <- session_id(opts) do
      run_action("clear_active_app", %{user_id: identity.user_id, session_id: session_id})
    end
  end

  defp route(["clear" | rest], _ctx) do
    {opts, [], invalid} = parse_opts(rest)

    with :ok <- reject_invalid(invalid),
         {:ok, identity} <- identity(opts),
         {:ok, session_id} <- session_id(opts),
         {:ok, result} <- Session.clear(identity.user_id, session_id) do
      {:ok, {:clear, identity.user_id, session_id, result}}
    end
  end

  defp route(["sweep" | rest], _ctx) do
    {opts, [], invalid} = parse_opts(rest)

    with :ok <- reject_invalid(invalid),
         {:ok, _identity} <- maybe_identity(opts),
         {:ok, count} <- Session.sweep_expired() do
      {:ok, {:sweep, count}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # -- rendering -------------------------------------------------------------

  defp render({:ok, {:list, []}}), do: Render.ok("No sessions.")

  defp render({:ok, {:list, entries}}) do
    Render.ok(
      Enum.map(entries, fn entry ->
        summary = Session.summary(entry)

        "#{summary.session_id} active_app=#{Session.active_app_label(summary.active_app)} ttl_ms=#{summary.remaining_ttl_ms} working_keys=#{summary.working_memory_key_count} metadata_keys=#{length(summary.metadata_keys)}"
      end)
    )
  end

  defp render({:ok, {:action, response}}) do
    Render.ok(session_lines(Map.fetch!(response, :session)))
  end

  defp render({:ok, {:clear, user_id, session_id, %{removed?: removed?}}}) do
    Render.ok("Session #{user_id}/#{session_id} removed=#{removed?}")
  end

  defp render({:ok, {:sweep, count}}) do
    Render.ok("Expired sessions removed=#{count}")
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:arg, message}}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("Sessions command failed: #{inspect(reason)}")

  defp session_lines(summary) do
    [
      "User: #{summary.user_id}",
      "Session: #{summary.session_id}",
      "Active app: #{Session.active_app_label(summary.active_app)}",
      "TTL ms: #{summary.remaining_ttl_ms}",
      "Metadata keys: #{Enum.join(summary.metadata_keys, ", ")}",
      "Working memory keys: #{Enum.join(summary.working_memory_keys, ", ")}",
      "Working memory key count: #{summary.working_memory_key_count}"
    ]
  end

  # -- action + read helpers -------------------------------------------------

  defp run_action(action, params) do
    with {:ok, response} <-
           Runner.run(action, params, %{request: Map.put(params, :channel, :cli)}) do
      case Map.get(response, :status) do
        :completed -> {:ok, {:action, response}}
        _status -> {:error, Map.get(response, :error, :action_failed)}
      end
    end
  end

  # -- argument parsing helpers ----------------------------------------------

  defp identity(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        {:error, {:arg, "--user and --operator must match when both are provided"}}

      user ->
        {:ok, %{user_id: user, operator_id: user}}

      operator ->
        {:ok, %{user_id: operator, operator_id: operator}}

      true ->
        {:ok, %{user_id: "local", operator_id: "local"}}
    end
  end

  defp maybe_identity(opts) do
    if opts[:user] || opts[:operator], do: identity(opts), else: {:ok, nil}
  end

  defp session_id(opts) do
    case Session.normalize_session_id(opts[:session]) do
      {:ok, session_id} -> {:ok, session_id}
      {:error, reason} -> {:error, {:arg, "--session is invalid: #{inspect(reason)}"}}
    end
  end

  defp single_arg([value], _message), do: {:ok, value}
  defp single_arg([], message), do: {:error, {:arg, message}}

  defp single_arg(args, _message),
    do: {:error, {:arg, "Expected one argument, got: #{inspect(args)}"}}

  defp parse_opts(args), do: OptionParser.parse(args, switches: @switches, aliases: @aliases)

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:arg, "Invalid option(s): #{inspect(invalid)}"}}

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
