defmodule Mix.Tasks.Allbert.Voice.Local do
  @moduledoc """
  Manage the Allbert-owned local voice runtime.

  ## Usage

      mix allbert.voice.local doctor
      mix allbert.voice.local start
      mix allbert.voice.local token
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Voice.LocalRuntime.Auth

  @shortdoc "Doctor and start the Allbert local voice runtime"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["doctor"]) do
    case Runner.run("voice_local_runtime_doctor", %{}, context()) do
      {:ok, response} -> {:ok, {:doctor, response}}
    end
  end

  defp dispatch(["start"]) do
    case Runner.run("voice_local_runtime_start", %{}, context()) do
      {:ok, %{status: :running} = response} -> {:ok, {:start, response}}
      {:ok, response} -> {:error, response}
    end
  end

  defp dispatch(["token"]) do
    {:ok, {:token, Auth.ensure_token!()}}
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.voice.local doctor
      mix allbert.voice.local start
      mix allbert.voice.local token
    """)
  end

  defp print_result({:ok, {:doctor, %{status: :completed} = response}}) do
    doctor = response.doctor
    Mix.shell().info(response.message)
    Mix.shell().info("settings_enabled=#{inspect(doctor.enabled?)}")
    Mix.shell().info("security_manage_decision=#{response.permission_decision.decision}")
    Mix.shell().info("base_url=#{doctor.base_url}")
    Mix.shell().info("bind=#{doctor.bind}")
    Mix.shell().info("stt_backend=#{doctor.stt.backend}")
    Mix.shell().info("stt_model=#{doctor.stt.model}")
    Mix.shell().info("stt_available=#{inspect(doctor.stt.available?)}")
    Mix.shell().info("tts_backend=#{doctor.tts.backend}")
    Mix.shell().info("tts_model=#{doctor.tts.model}")
    Mix.shell().info("tts_available=#{inspect(doctor.tts.available?)}")
    Mix.shell().info("models=#{Enum.map_join(doctor.models, ",", & &1.id)}")

    Mix.shell().info(
      "diagnostic_codes=#{Enum.map_join(doctor.diagnostic_codes, ",", &to_string/1)}"
    )

    Mix.shell().info("token_path=#{Auth.token_path()}")
  end

  defp print_result({:ok, {:doctor, response}}) do
    Mix.raise("Local voice runtime doctor failed: #{inspect(response)}")
  end

  defp print_result({:ok, {:start, response}}) do
    Mix.shell().info(response.message)
    Mix.shell().info("bind=#{response.bind}")
    Mix.shell().info("base_url=#{response.base_url}")
    Mix.shell().info("token_path=#{response.token_path}")
    Mix.shell().info("Press Ctrl+C twice to stop.")
    Process.sleep(:infinity)
  end

  defp print_result({:ok, {:token, token}}) do
    Mix.shell().info(token)
  end

  defp print_result({:error, response}) do
    Mix.raise("Local voice runtime command failed: #{response_error(response)}")
  end

  defp context, do: %{actor: "local", channel: :cli}

  defp response_error(%{message: message, error: error}), do: "#{message} #{inspect(error)}"
  defp response_error(%{message: message}), do: message
  defp response_error(response), do: inspect(response)
end
