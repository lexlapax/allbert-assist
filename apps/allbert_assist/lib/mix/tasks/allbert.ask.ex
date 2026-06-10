defmodule Mix.Tasks.Allbert.Ask do
  @moduledoc """
  Send one prompt through the Allbert runtime boundary.

  ## Usage

      mix allbert.ask "remember that I like concise milestone handoffs"
      mix allbert.ask --trace "what do you remember about milestone handoffs?"
      mix allbert.ask --user alice --new-thread "hello"
      mix allbert.ask --user alice --thread THREAD_ID "continue"
      mix allbert.ask --user alice --session SESSION_ID "hello"
      mix allbert.ask --user alice --active-app stocksage "list my analyses"
      mix allbert.ask --voice test/fixtures/audio/hello.wav --trace
      mix allbert.ask --voice test/fixtures/audio/hello.wav --speak

  ## Options

    * `--trace` - enable markdown trace recording for this turn
    * `--voice` - transcribe an explicit local audio file before submitting text
    * `--speak` - synthesize the runtime response after the text turn
    * `--channel` - channel label to send to the runtime, defaults to `cli`
    * `--user` - canonical local user id, defaults to `local`
    * `--operator` - legacy local operator id alias
    * `--thread` - continue an existing user-owned thread
    * `--new-thread` - create a fresh general thread
    * `--session` - volatile local session id for scratchpad lookup
    * `--active-app` - app context for this one CLI turn
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels.LocalSurface
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.MediaOutputs
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
    active_app: :string,
    voice: :string,
    speak: :boolean,
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
    voice_file = blank_to_nil(opts[:voice])

    if prompt == "" and is_nil(voice_file) do
      Mix.raise(
        "Usage: mix allbert.ask [--trace] [--voice AUDIO_FILE] [--channel cli] [--user local|--operator local] [--thread THREAD_ID|--new-thread] [--session SESSION_ID] [--active-app APP_ID] \"prompt\""
      )
    end

    validate_identity!(opts)
    validate_thread_options!(opts)
    validate_session!(opts)

    if opts[:trace] do
      enable_trace_for_turn()
    end

    voice_result = maybe_transcribe_voice!(voice_file, opts)
    prompt = prompt_with_voice(prompt, voice_result)

    result = submit(prompt, opts, voice_result)
    speech_result = maybe_synthesize_speech!(result, opts)

    print_result(result)
    print_speech_result(speech_result)
  end

  defp enable_trace_for_turn do
    trace_config =
      :allbert_assist
      |> Application.get_env(Trace, [])
      |> Keyword.put(:enabled, true)

    Application.put_env(:allbert_assist, Trace, trace_config)
  end

  defp submit(prompt, opts, voice_result) do
    channel = opts[:channel] || :cli
    user_id = blank_to_nil(opts[:user]) || blank_to_nil(opts[:operator]) || "local"
    request_id = Ecto.UUID.generate()

    %{
      text: prompt,
      channel: channel
    }
    |> maybe_put(:user_id, blank_to_nil(opts[:user]))
    |> maybe_put(:operator_id, blank_to_nil(opts[:operator]))
    |> maybe_put(:thread_id, blank_to_nil(opts[:thread]))
    |> maybe_put(:session_id, blank_to_nil(opts[:session]))
    |> maybe_put(:active_app, blank_to_nil(opts[:active_app]))
    |> maybe_put(:new_thread, opts[:new_thread])
    |> maybe_put_local_surface_ref(channel, %{
      request_id: request_id,
      user_id: user_id,
      thread_id: blank_to_nil(opts[:thread]),
      session_id: blank_to_nil(opts[:session])
    })
    |> merge_metadata(voice_request_metadata(voice_result))
    |> Runtime.submit_user_input()
  end

  defp maybe_put_local_surface_ref(attrs, channel, ref_attrs) do
    case LocalSurface.thread_ref(channel, ref_attrs) do
      {:ok, ref} ->
        attrs
        |> Map.put(:channel_thread_ref, ref.channel_thread_ref)
        |> Map.put(:provider_message_id, ref.provider_message_id)
        |> merge_metadata(ref.metadata)

      {:error, :unknown_local_surface} ->
        attrs
    end
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
    print_media_outputs(Map.get(response, :media_outputs, []))
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

  defp print_speech_result(nil), do: :ok

  defp print_speech_result(%{audio_file: audio_file, output_resource_uri: output_resource_uri}) do
    Mix.shell().info("")
    Mix.shell().info("Speech: #{output_resource_uri}")
    Mix.shell().info("Speech file: #{audio_file}")
    :ok
  end

  defp print_media_outputs(outputs) do
    outputs = MediaOutputs.persistable(outputs)

    if outputs != [] do
      Mix.shell().info("Media outputs:")
      Enum.each(outputs, &print_media_output/1)
    end
  end

  defp print_media_output(output) do
    kind = Map.get(output, :kind) || Map.get(output, "kind") || "media"
    mime_type = Map.get(output, :mime_type) || Map.get(output, "mime_type")
    resource_uri = Map.get(output, :resource_uri) || Map.get(output, "resource_uri")
    local_path = Map.get(output, :local_path) || Map.get(output, "local_path")

    Mix.shell().info("- #{kind} #{media_output_detail(mime_type, resource_uri, local_path)}")
  end

  defp media_output_detail(mime_type, resource_uri, local_path) do
    [mime_type, resource_uri, local_path]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
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

  defp maybe_transcribe_voice!(nil, _opts), do: nil

  defp maybe_transcribe_voice!(voice_file, opts) do
    case Runner.run("transcribe_voice", %{audio_file: voice_file}, voice_action_context(opts)) do
      {:ok, %{status: :completed, transcript: transcript} = response}
      when is_binary(transcript) ->
        response

      {:ok, response} ->
        Mix.raise("Voice transcription failed: #{Map.get(response, :message, inspect(response))}")
    end
  end

  defp maybe_synthesize_speech!(result, opts) do
    if opts[:speak] == true do
      synthesize_speech!(result, opts)
    end
  end

  defp synthesize_speech!({:ok, %{status: status, message: message}}, opts)
       when status in [:completed, "completed"] and is_binary(message) do
    case Runner.run("synthesize_voice", %{text: message}, voice_action_context(opts)) do
      {:ok, %{status: :completed} = response} ->
        response

      {:ok, response} ->
        Mix.raise("Voice synthesis failed: #{Map.get(response, :message, inspect(response))}")
    end
  end

  defp synthesize_speech!({:ok, response}, _opts) do
    Mix.raise("Voice synthesis skipped because runtime status was #{inspect(response.status)}")
  end

  defp synthesize_speech!({:error, _reason}, _opts), do: nil

  defp voice_action_context(opts) do
    %{
      actor: blank_to_nil(opts[:user]) || blank_to_nil(opts[:operator]) || "local",
      channel: opts[:channel] || :cli,
      request: %{
        channel: opts[:channel] || :cli,
        operator_id: blank_to_nil(opts[:operator]) || blank_to_nil(opts[:user]) || "local"
      }
    }
  end

  defp prompt_with_voice(prompt, nil), do: prompt

  defp prompt_with_voice("", %{transcript: transcript}), do: transcript

  defp prompt_with_voice(prompt, %{transcript: transcript}),
    do: Enum.join([prompt, transcript], "\n\n")

  defp voice_request_metadata(nil), do: nil

  defp voice_request_metadata(%{voice_metadata: voice_metadata}) do
    %{voice: voice_metadata}
  end

  defp merge_metadata(params, nil), do: params

  defp merge_metadata(params, metadata) when is_map(metadata) do
    Map.update(params, :metadata, metadata, &Map.merge(&1, metadata))
  end

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
