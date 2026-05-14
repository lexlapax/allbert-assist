defmodule Mix.Tasks.Allbert.Ask do
  @moduledoc """
  Send one prompt through the Allbert runtime boundary.

  ## Usage

      mix allbert.ask "remember that I like concise milestone handoffs"
      mix allbert.ask --trace "what do you remember about milestone handoffs?"
      mix allbert.ask --user alice --new-thread "hello"
      mix allbert.ask --user alice --thread THREAD_ID "continue"
      mix allbert.ask --user alice --session SESSION_ID "hello"

  ## Options

    * `--trace` - enable markdown trace recording for this turn
    * `--channel` - channel label to send to the runtime, defaults to `cli`
    * `--user` - canonical local user id, defaults to `local`
    * `--operator` - legacy local operator id alias
    * `--thread` - continue an existing user-owned thread
    * `--new-thread` - create a fresh general thread
    * `--session` - volatile local session id for scratchpad lookup
  """

  use Mix.Task

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssist.Session
  alias AllbertAssist.Trace

  @shortdoc "Send one prompt through the Allbert runtime"
  @switches [
    channel: :string,
    operator: :string,
    session: :string,
    user: :string,
    thread: :string,
    new_thread: :boolean,
    trace: :boolean
  ]

  @aliases [
    c: :channel,
    o: :operator,
    s: :session,
    u: :user,
    t: :thread
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, prompt_parts, invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    prompt = prompt_parts |> Enum.join(" ") |> String.trim()

    if prompt == "" do
      Mix.raise(
        "Usage: mix allbert.ask [--trace] [--channel cli] [--user local|--operator local] [--thread THREAD_ID|--new-thread] [--session SESSION_ID] \"prompt\""
      )
    end

    validate_identity!(opts)
    validate_thread_options!(opts)
    validate_session!(opts)

    if opts[:trace] do
      enable_trace_for_turn()
    end

    prompt
    |> submit(opts)
    |> print_result()
  end

  defp enable_trace_for_turn do
    trace_config =
      :allbert_assist
      |> Application.get_env(Trace, [])
      |> Keyword.put(:enabled, true)

    Application.put_env(:allbert_assist, Trace, trace_config)
  end

  defp submit(prompt, opts) do
    %{
      text: prompt,
      channel: opts[:channel] || :cli
    }
    |> maybe_put(:user_id, blank_to_nil(opts[:user]))
    |> maybe_put(:operator_id, blank_to_nil(opts[:operator]))
    |> maybe_put(:thread_id, blank_to_nil(opts[:thread]))
    |> maybe_put(:session_id, blank_to_nil(opts[:session]))
    |> maybe_put(:new_thread, opts[:new_thread])
    |> Runtime.submit_user_input()
  end

  defp print_result({:ok, response}) do
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info("")
    Mix.shell().info(response.message)
    Mix.shell().info("")
    Mix.shell().info("Signal: #{response.signal_id}")
    Mix.shell().info("Trace: #{response.trace_id || "none"}")
    Mix.shell().info("User: #{response.user_id}")
    Mix.shell().info("Thread: #{response.thread_id}")
    print_session(response)
    print_approval_handoff(Map.get(response, :approval_handoff))

    if response.diagnostics != [] do
      Mix.shell().info("Diagnostics: #{inspect(response.diagnostics, pretty: true)}")
    end

    if response.actions != [] do
      Mix.shell().info("Actions:")
      Enum.each(response.actions, &print_action/1)
    end

    :ok
  end

  defp print_result({:error, reason}) do
    Mix.raise("Allbert request failed: #{inspect(reason)}")
  end

  defp print_action(action) do
    name = Map.get(action, :name) || Map.get(action, "name") || "unknown"
    status = Map.get(action, :status) || Map.get(action, "status") || "unknown"
    Mix.shell().info("- #{name} (#{status})")
    print_action_field("  Execution", Map.get(action, :execution) || Map.get(action, "execution"))
    print_action_field("  Confirmation", confirmation_id(action))

    print_action_field(
      "  Command",
      command_line(Map.get(action, :command) || Map.get(action, "command"))
    )

    print_action_field(
      "  Denial",
      Map.get(action, :denial_reason) || Map.get(action, "denial_reason")
    )
  end

  defp print_approval_handoff(nil), do: :ok

  defp print_approval_handoff(handoff) do
    lines = ApprovalHandoff.lines(handoff)
    confirmation_id = Map.get(handoff, :confirmation_id) || Map.get(handoff, "confirmation_id")

    if lines != [] do
      Mix.shell().info("")
      Mix.shell().info("Approval Handoff:")
      Enum.each(lines, &Mix.shell().info("  #{&1}"))
      print_approval_commands(confirmation_id)
    end
  end

  defp print_approval_commands(nil), do: :ok

  defp print_approval_commands(confirmation_id) do
    Mix.shell().info("  Details: mix allbert.confirmations show #{confirmation_id}")
    Mix.shell().info("  Approve: mix allbert.confirmations approve #{confirmation_id}")
    Mix.shell().info("  Deny: mix allbert.confirmations deny #{confirmation_id}")
  end

  defp print_action_field(_label, nil), do: :ok
  defp print_action_field(_label, ""), do: :ok
  defp print_action_field(label, value), do: Mix.shell().info("#{label}: #{value}")

  defp confirmation_id(action) do
    Map.get(action, :confirmation_id) || Map.get(action, "confirmation_id")
  end

  defp command_line(%{} = command) do
    executable = Map.get(command, :executable) || Map.get(command, "executable")
    args = Map.get(command, :args) || Map.get(command, "args") || []

    if is_binary(executable), do: Enum.join([executable | args], " "), else: nil
  end

  defp command_line(_command), do: nil

  defp validate_identity!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    if user && operator && user != operator do
      Mix.raise("--user and --operator must match when both are provided")
    end
  end

  defp validate_thread_options!(opts) do
    if blank_to_nil(opts[:thread]) && opts[:new_thread] do
      Mix.raise("--thread and --new-thread cannot be used together")
    end
  end

  defp validate_session!(opts) do
    case Keyword.fetch(opts, :session) do
      :error ->
        :ok

      {:ok, session_id} ->
        case Session.normalize_session_id(session_id) do
          {:ok, _session_id} -> :ok
          {:error, reason} -> Mix.raise("--session is invalid: #{inspect(reason)}")
        end
    end
  end

  defp print_session(response) do
    if response.session_id do
      Mix.shell().info("Session: #{response.session_id}")
    end

    Mix.shell().info("Active app: #{Session.active_app_label(Map.get(response, :active_app))}")
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, false), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

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
