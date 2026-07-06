defmodule AllbertAssist.CLI.Areas.Voice do
  @moduledoc """
  Release-safe `voice` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.voice.local` and
  `allbert admin voice`: `dispatch/2` parses the sub-argv, routes to the same
  registered actions the Mix task used, and returns `{rendered_output,
  exit_code}` — no `Mix.*` calls, so it runs inside the packaged release.
  `Mix.Tasks.Allbert.Voice.Local` is a thin wrapper that prints the output
  through `Mix.shell/0`.

  The `start` subcommand launches a foreground runtime: it emits its status
  output and then holds the process (like `serve`), so `dispatch/2` blocks and
  does not return for that path — exactly as the original Mix task's
  `Process.sleep(:infinity)`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Voice.LocalRuntime.Auth

  @usage """
  Usage:
    mix allbert.voice.local doctor
    mix allbert.voice.local start
    mix allbert.voice.local token
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil)

  # `start` is a foreground runtime: emit its output, then hold the process so
  # the runtime keeps serving (matches the Mix task's `Process.sleep(:infinity)`).
  def dispatch(["start"] = argv, context) do
    case route(argv, context || default_context()) do
      {:ok, {:start, _response}} = result ->
        {output, 0} = rendered = render(result)
        IO.puts(output)
        Process.sleep(:infinity)
        rendered

      other ->
        render(other)
    end
  end

  def dispatch(argv, context) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin voice")

  defp route(["doctor"], ctx) do
    case Runner.run("voice_local_runtime_doctor", %{}, ctx) do
      {:ok, %{status: :completed} = response} -> {:ok, {:doctor, response}}
      {:ok, response} -> {:error, {:doctor_failed, response}}
    end
  end

  defp route(["start"], ctx) do
    case Runner.run("voice_local_runtime_start", %{}, ctx) do
      {:ok, %{status: :running} = response} -> {:ok, {:start, response}}
      {:ok, response} -> {:error, {:start_failed, response}}
    end
  end

  defp route(["token"], _ctx) do
    {:ok, {:token, Auth.ensure_token!()}}
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:doctor, response}}) do
    doctor = response.doctor

    Render.ok([
      response.message,
      "settings_enabled=#{inspect(doctor.enabled?)}",
      "security_manage_decision=#{response.permission_decision.decision}",
      "base_url=#{doctor.base_url}",
      "bind=#{doctor.bind}",
      "stt_backend=#{doctor.stt.backend}",
      "stt_model=#{doctor.stt.model}",
      "stt_available=#{inspect(doctor.stt.available?)}",
      "tts_backend=#{doctor.tts.backend}",
      "tts_model=#{doctor.tts.model}",
      "tts_available=#{inspect(doctor.tts.available?)}",
      "models=#{Enum.map_join(doctor.models, ",", & &1.id)}",
      "diagnostic_codes=#{Enum.map_join(doctor.diagnostic_codes, ",", &to_string/1)}",
      "token_path=#{Auth.token_path()}"
    ])
  end

  defp render({:ok, {:start, response}}) do
    Render.ok([
      response.message,
      "bind=#{response.bind}",
      "base_url=#{response.base_url}",
      "token_path=#{response.token_path}",
      "Press Ctrl+C twice to stop."
    ])
  end

  defp render({:ok, {:token, token}}), do: Render.ok(token)

  defp render({:error, {:doctor_failed, response}}) do
    Render.error("Local voice runtime doctor failed: #{inspect(response)}")
  end

  defp render({:error, {:start_failed, response}}) do
    Render.error("Local voice runtime command failed: #{response_error(response)}")
  end

  defp render({:usage, usage}), do: Render.usage(usage)

  defp response_error(%{message: message, error: error}), do: "#{message} #{inspect(error)}"
  defp response_error(%{message: message}), do: message
  defp response_error(response), do: inspect(response)
end
