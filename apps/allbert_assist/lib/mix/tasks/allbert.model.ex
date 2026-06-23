defmodule Mix.Tasks.Allbert.Model do
  @moduledoc """
  Inspect and select Allbert model profiles.

  ## Usage

      mix allbert.model list
      mix allbert.model use PROFILE [--enable-assist]
      mix allbert.model doctor PROFILE
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings

  @shortdoc "Inspect, select, and doctor model profiles"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list"]) do
    with {:ok, providers_response} <-
           completed_action("list_provider_profiles", %{render_mode: "operator_report"}),
         {:ok, models_response} <-
           completed_action("list_model_profiles", %{render_mode: "operator_report"}),
         {:ok, active_profile} <- Settings.get("intent.model_profile"),
         {:ok, assist_enabled?} <- Settings.get("intent.model_assist_enabled") do
      {:ok,
       {:list, providers_response.providers, models_response.models, active_profile,
        assist_enabled?}}
    end
  end

  defp dispatch(["doctor", profile]) do
    with {:ok, response} <- completed_action(doctor_action(profile), %{profile: profile}) do
      {:ok, {:doctor, response}}
    end
  end

  defp dispatch(["use", profile | args]) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [enable_assist: :boolean])

    reject_invalid!(invalid)
    reject_rest!(rest)

    params =
      %{profile: profile}
      |> maybe_put(:enable_assist, Keyword.get(opts, :enable_assist))

    with {:ok, response} <- completed_action("set_active_model_profile", params) do
      {:ok, {:use, response}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.model list
      mix allbert.model use PROFILE [--enable-assist]
      mix allbert.model doctor PROFILE
    """)
  end

  defp print_result({:ok, {:list, providers, models, active_profile, assist_enabled?}}) do
    Mix.shell().info("Active model profile: #{active_profile}")
    Mix.shell().info("Model-assisted intent: #{inspect(assist_enabled?)}")
    Mix.shell().info("")
    Mix.shell().info("Providers:")

    Enum.each(providers, fn provider ->
      Mix.shell().info(
        "- #{provider.name}: type=#{provider.type} endpoint_kind=#{provider.endpoint_kind} enabled=#{provider.enabled} credential=#{provider.credential_status}"
      )
    end)

    Mix.shell().info("")
    Mix.shell().info("Models:")

    Enum.each(models, fn model ->
      active = if model.name == active_profile, do: " active", else: ""

      Mix.shell().info(
        "- #{model.name}: provider=#{model.provider} model=#{model.model} endpoint_kind=#{model.provider_endpoint_kind} credential=#{model.credential_status}#{active}"
      )
    end)
  end

  defp print_result({:ok, {:doctor, response}}) do
    doctor = response.doctor

    Mix.shell().info(response.message)
    Mix.shell().info("endpoint_kind=#{doctor.endpoint_kind}")
    Mix.shell().info("credential_ok=#{inspect(doctor.credential_ok)}")
    Mix.shell().info("endpoint_ok=#{doctor.endpoint_ok}")
    Mix.shell().info("model_available=#{inspect(doctor.model_available)}")
    Mix.shell().info("redacted_host=#{doctor.redacted_host}")
    print_voice_doctor_fields(doctor)

    Enum.each(doctor.diagnostics, fn diagnostic ->
      Mix.shell().info("diagnostic=#{diagnostic.code}: #{diagnostic.message}")
    end)
  end

  defp print_result({:ok, {:use, response}}) do
    Mix.shell().info(response.message)
    print_audits(response.settings)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Model command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error

  defp response_error(%{actions: actions, message: message}) when is_list(actions) do
    actions
    |> Enum.find_value(&get_in(&1, [:settings_metadata, :error]))
    |> case do
      nil -> message
      error -> error
    end
  end

  defp response_error(%{message: message}), do: message

  defp context, do: %{actor: "local", channel: :cli}

  defp doctor_action(profile) do
    case Settings.resolve_model_profile(profile) do
      {:ok, model_profile} ->
        if voice_capable?(model_profile),
          do: "doctor_voice_provider",
          else: "doctor_model_profile"

      {:error, _reason} ->
        "doctor_model_profile"
    end
  end

  defp voice_capable?(%{capabilities: capabilities}) when is_list(capabilities) do
    Enum.any?(capabilities, &(&1 in ["speech_to_text", "text_to_speech"]))
  end

  defp voice_capable?(_profile), do: false

  defp print_voice_doctor_fields(%{provider_capabilities: capabilities} = doctor) do
    Mix.shell().info("provider_capabilities=#{Enum.join(capabilities, ",")}")
    Mix.shell().info("provider_deployment_mode=#{inspect(doctor.provider_deployment_mode)}")
    Mix.shell().info("speech_to_text_supported=#{inspect(doctor.speech_to_text_supported)}")
    Mix.shell().info("text_to_speech_supported=#{inspect(doctor.text_to_speech_supported)}")
    Mix.shell().info("audio_formats_supported=#{inspect(doctor.audio_formats_supported)}")

    Mix.shell().info(
      "audio_sample_rates_supported=#{inspect(doctor.audio_sample_rates_supported)}"
    )
  end

  defp print_voice_doctor_fields(_doctor), do: :ok

  defp print_audits(settings) do
    settings
    |> Enum.flat_map(& &1.diagnostics)
    |> Enum.each(fn
      %{audit_path: audit_path} -> Mix.shell().info("Audit: #{audit_path}")
      _diagnostic -> :ok
    end)
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

  defp reject_rest!([]), do: :ok
  defp reject_rest!(rest), do: Mix.raise("Unexpected argument(s): #{Enum.join(rest, " ")}")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
