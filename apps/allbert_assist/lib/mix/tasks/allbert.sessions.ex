defmodule Mix.Tasks.Allbert.Sessions do
  @moduledoc """
  Inspect and control volatile local session scratchpad entries.

  ## Usage

      mix allbert.sessions list [--user USER]
      mix allbert.sessions show --user USER --session SESSION_ID
      mix allbert.sessions set-active-app --user USER --session SESSION_ID APP
      mix allbert.sessions clear-active-app --user USER --session SESSION_ID
      mix allbert.sessions clear --user USER --session SESSION_ID
      mix allbert.sessions sweep
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Session

  @shortdoc "Inspect and control volatile session scratchpad entries"

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

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    user_id = identity!(opts).user_id

    with {:ok, entries} <- Session.list(user_id) do
      {:ok, {:list, entries}}
    end
  end

  defp dispatch(["show" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    identity = identity!(opts)
    session_id = session_id!(opts)

    run_action("show_session_scratchpad", %{user_id: identity.user_id, session_id: session_id})
  end

  defp dispatch(["set-active-app" | rest]) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)
    identity = identity!(opts)
    session_id = session_id!(opts)
    app_id = single_arg!(args, "APP is required")

    run_action("set_active_app", %{
      user_id: identity.user_id,
      session_id: session_id,
      app_id: app_id
    })
  end

  defp dispatch(["clear-active-app" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    identity = identity!(opts)
    session_id = session_id!(opts)

    run_action("clear_active_app", %{user_id: identity.user_id, session_id: session_id})
  end

  defp dispatch(["clear" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    identity = identity!(opts)
    session_id = session_id!(opts)

    with {:ok, result} <- Session.clear(identity.user_id, session_id) do
      {:ok, {:clear, identity.user_id, session_id, result}}
    end
  end

  defp dispatch(["sweep" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    _identity = maybe_identity!(opts)

    with {:ok, count} <- Session.sweep_expired() do
      {:ok, {:sweep, count}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.sessions list [--user USER]
      mix allbert.sessions show --user USER --session SESSION_ID
      mix allbert.sessions set-active-app --user USER --session SESSION_ID APP
      mix allbert.sessions clear-active-app --user USER --session SESSION_ID
      mix allbert.sessions clear --user USER --session SESSION_ID
      mix allbert.sessions sweep
    """)
  end

  defp print_result({:ok, {:list, []}}), do: Mix.shell().info("No sessions.")

  defp print_result({:ok, {:list, entries}}) do
    Enum.each(entries, fn entry ->
      summary = Session.summary(entry)

      Mix.shell().info(
        "#{summary.session_id} active_app=#{Session.active_app_label(summary.active_app)} ttl_ms=#{summary.remaining_ttl_ms} working_keys=#{summary.working_memory_key_count} metadata_keys=#{length(summary.metadata_keys)}"
      )
    end)
  end

  defp print_result({:ok, {:action, response}}) do
    print_session(Map.fetch!(response, :session))
  end

  defp print_result({:ok, {:clear, user_id, session_id, %{removed?: removed?}}}) do
    Mix.shell().info("Session #{user_id}/#{session_id} removed=#{removed?}")
  end

  defp print_result({:ok, {:sweep, count}}) do
    Mix.shell().info("Expired sessions removed=#{count}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Sessions command failed: #{inspect(reason)}")
  end

  defp print_session(summary) do
    Mix.shell().info("User: #{summary.user_id}")
    Mix.shell().info("Session: #{summary.session_id}")
    Mix.shell().info("Active app: #{Session.active_app_label(summary.active_app)}")
    Mix.shell().info("TTL ms: #{summary.remaining_ttl_ms}")
    Mix.shell().info("Metadata keys: #{Enum.join(summary.metadata_keys, ", ")}")
    Mix.shell().info("Working memory keys: #{Enum.join(summary.working_memory_keys, ", ")}")
    Mix.shell().info("Working memory key count: #{summary.working_memory_key_count}")
  end

  defp run_action(action, params) do
    with {:ok, response} <-
           Runner.run(action, params, %{request: Map.put(params, :channel, :cli)}) do
      case Map.get(response, :status) do
        :completed -> {:ok, {:action, response}}
        _status -> {:error, Map.get(response, :error, :action_failed)}
      end
    end
  end

  defp identity!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        Mix.raise("--user and --operator must match when both are provided")

      user ->
        %{user_id: user, operator_id: user}

      operator ->
        %{user_id: operator, operator_id: operator}

      true ->
        %{user_id: "local", operator_id: "local"}
    end
  end

  defp maybe_identity!(opts) do
    if opts[:user] || opts[:operator], do: identity!(opts), else: nil
  end

  defp session_id!(opts) do
    case Session.normalize_session_id(opts[:session]) do
      {:ok, session_id} -> session_id
      {:error, reason} -> Mix.raise("--session is invalid: #{inspect(reason)}")
    end
  end

  defp single_arg!([value], _message), do: value
  defp single_arg!([], message), do: Mix.raise(message)
  defp single_arg!(args, _message), do: Mix.raise("Expected one argument, got: #{inspect(args)}")

  defp parse!(args), do: OptionParser.parse(args, switches: @switches, aliases: @aliases)

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

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
