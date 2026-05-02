defmodule Mix.Tasks.Allbert.Ask do
  @moduledoc """
  Send one prompt through the Allbert runtime boundary.

  ## Usage

      mix allbert.ask "remember that I like concise milestone handoffs"
      mix allbert.ask --trace "what do you remember about milestone handoffs?"

  ## Options

    * `--trace` - enable markdown trace recording for this turn
    * `--channel` - channel label to send to the runtime, defaults to `cli`
    * `--operator` - local operator id, defaults to `local`
  """

  use Mix.Task

  alias AllbertAssist.Runtime
  alias AllbertAssist.Trace

  @shortdoc "Send one prompt through the Allbert runtime"
  @switches [
    channel: :string,
    operator: :string,
    trace: :boolean
  ]

  @aliases [
    c: :channel,
    o: :operator
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
      Mix.raise("Usage: mix allbert.ask [--trace] [--channel cli] [--operator local] \"prompt\"")
    end

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
    Runtime.submit_user_input(%{
      text: prompt,
      channel: opts[:channel] || :cli,
      operator_id: opts[:operator] || "local"
    })
  end

  defp print_result({:ok, response}) do
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info("")
    Mix.shell().info(response.message)
    Mix.shell().info("")
    Mix.shell().info("Signal: #{response.signal_id}")
    Mix.shell().info("Trace: #{response.trace_id || "none"}")

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
end
