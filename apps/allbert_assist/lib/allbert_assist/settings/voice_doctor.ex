defmodule AllbertAssist.Settings.VoiceDoctor do
  @moduledoc """
  Capability-aware voice provider doctor.

  The doctor reads configured Settings Central model profiles and reports the
  ADR 0047 voice doctor fields. It is diagnostic only and grants no audio
  permissions or provider authority.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.DoctorDiagnostics
  alias AllbertAssist.Voice.ProviderAdapter

  @voice_capabilities ~w[speech_to_text text_to_speech]
  @deployment_modes ~w[fake local_endpoint bundled_local remote_credentialed]

  @spec diagnose(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def diagnose(profile_name, context \\ %{})

  def diagnose(profile_name, _context) when is_binary(profile_name) do
    with {:ok, model_profile} <- Settings.resolve_model_profile(profile_name),
         {:ok, provider_profile} <- Settings.resolve_provider_profile(model_profile.provider) do
      {:ok,
       model_profile
       |> voice_summary(provider_profile)
       |> Map.put(:profile, profile_name)
       |> Map.put(:model, model_profile.model)
       |> Map.put(:provider, provider_profile.name)
       |> Map.put(:provider_type, provider_profile.type)}
    end
  end

  def diagnose(_profile_name, _context), do: {:error, :invalid_model_profile}

  defp voice_summary(model_profile, provider_profile) do
    capabilities = voice_capabilities(model_profile)
    deployment_mode = deployment_mode(model_profile)

    if capabilities == [] do
      summary(model_profile, provider_profile, capabilities, deployment_mode,
        endpoint_ok: false,
        model_available: false,
        diagnostics: [diagnostic(:voice_capability_missing)]
      )
    else
      adapter_summary(model_profile)
      |> case do
        {:ok, adapter} ->
          summary(model_profile, provider_profile, capabilities, deployment_mode,
            endpoint_ok: Map.fetch!(adapter, :endpoint_ok),
            model_available: Map.fetch!(adapter, :model_available),
            provider_usage_metadata_available:
              Map.get(adapter, :provider_usage_metadata_available, :unknown),
            fixture_probe_ok: Map.get(adapter, :fixture_probe_ok),
            local_runtime_present: Map.get(adapter, :local_runtime_present),
            redacted_host: Map.get(adapter, :redacted_host, redacted_host(provider_profile)),
            diagnostics: diagnostics(adapter)
          )

        {:error, reason} ->
          summary(model_profile, provider_profile, capabilities, deployment_mode,
            endpoint_ok: false,
            model_available: :unknown,
            provider_usage_metadata_available: :unknown,
            diagnostics: [diagnostic(reason)]
          )
      end
    end
  end

  defp adapter_summary(model_profile), do: ProviderAdapter.doctor(model_profile)

  defp diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics), do: diagnostics

  defp diagnostics(%{diagnostic_codes: codes}) when is_list(codes) do
    Enum.map(codes, &diagnostic/1)
  end

  defp diagnostics(_adapter), do: []

  defp diagnostic({:voice_adapter_unavailable, _mode}),
    do: DoctorDiagnostics.new(:voice_provider_probe_unavailable)

  defp diagnostic(code) when is_atom(code), do: DoctorDiagnostics.new(code)

  defp diagnostic(_reason), do: DoctorDiagnostics.new(:voice_provider_probe_unavailable)

  defp summary(model_profile, provider_profile, capabilities, deployment_mode, opts) do
    endpoint_kind = endpoint_kind(provider_profile.endpoint_kind)

    %{
      endpoint_kind: endpoint_kind,
      credential_ok: credential_ok(endpoint_kind, provider_profile),
      endpoint_ok: Keyword.fetch!(opts, :endpoint_ok),
      model_available: Keyword.fetch!(opts, :model_available),
      context_window: nil,
      deprecation_warning: nil,
      last_seen_rate_limit_hint: nil,
      redacted_host: Keyword.get(opts, :redacted_host, redacted_host(provider_profile)),
      diagnostics: Keyword.get(opts, :diagnostics, []),
      provider_capabilities: capabilities,
      provider_deployment_mode: deployment_mode,
      speech_to_text_supported: "speech_to_text" in capabilities,
      text_to_speech_supported: "text_to_speech" in capabilities,
      audio_formats_supported: media_field(model_profile, "audio_formats_supported", :unknown),
      audio_sample_rates_supported:
        media_field(model_profile, "audio_sample_rates_supported", :unknown),
      provider_usage_metadata_available:
        Keyword.get(opts, :provider_usage_metadata_available, :unknown),
      local_runtime_present: Keyword.get(opts, :local_runtime_present),
      fixture_probe_ok: Keyword.get(opts, :fixture_probe_ok)
    }
  end

  defp voice_capabilities(%{capabilities: capabilities}) when is_list(capabilities) do
    Enum.filter(capabilities, &(&1 in @voice_capabilities))
  end

  defp voice_capabilities(_profile), do: []

  defp deployment_mode(%{media: %{"deployment_mode" => mode}}) when mode in @deployment_modes do
    String.to_atom(mode)
  end

  defp deployment_mode(_profile), do: nil

  defp media_field(%{media: media}, field, fallback) when is_map(media) do
    Map.get(media, field, fallback)
  end

  defp media_field(_profile, _field, fallback), do: fallback

  defp endpoint_kind("local_endpoint"), do: :local_endpoint
  defp endpoint_kind("credentialed_remote"), do: :credentialed_remote
  defp endpoint_kind(_other), do: :credentialed_remote

  defp credential_ok(:credentialed_remote, %{credential_status: :configured}), do: true
  defp credential_ok(:credentialed_remote, _provider), do: false
  defp credential_ok(_endpoint_kind, _provider), do: nil

  defp redacted_host(%{base_url: base_url}) when is_binary(base_url) do
    base_url
    |> URI.parse()
    |> case do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _uri -> "unknown"
    end
  end

  defp redacted_host(%{name: name}) when is_binary(name), do: name
  defp redacted_host(_provider), do: "unknown"
end
