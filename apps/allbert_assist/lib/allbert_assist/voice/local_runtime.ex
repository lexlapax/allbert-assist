defmodule AllbertAssist.Voice.LocalRuntime do
  @moduledoc """
  Allbert-owned loopback voice runtime.

  The runtime exposes an OpenAI-compatible local STT/TTS surface while keeping
  the actual local backends doctored and replaceable. It never accepts
  credentials and never widens provider/action authority; callers still reach it
  through the existing voice actions and local provider adapter.
  """

  alias AllbertAssist.Voice.LocalRuntime.Config

  def doctor(opts \\ []) do
    config = ensure_config(opts)
    stt = config.stt_backend.doctor(config)
    tts = config.tts_backend.doctor(config)

    %{
      endpoint_ok: true,
      local_runtime_present: true,
      enabled?: config.enabled?,
      base_url: config.base_url,
      bind: "127.0.0.1",
      stt: stt,
      tts: tts,
      diagnostic_codes: diagnostic_codes(stt, tts),
      models: models_from_doctor(config, stt, tts)
    }
  end

  def models(opts \\ []) do
    config = ensure_config(opts)
    doctor = doctor(config)

    %{
      object: "list",
      data: doctor.models
    }
  end

  @spec transcribe(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def transcribe(path, params, opts \\ []) when is_binary(path) and is_map(params) do
    config = ensure_config(opts)

    with :ok <- expected_model(params, config.stt_model_alias),
         :ok <- backend_available(config.stt_backend.doctor(config), :speech_to_text) do
      config.stt_backend.transcribe(path, params, config)
    end
  end

  @spec synthesize(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def synthesize(text, params, opts \\ []) when is_binary(text) and is_map(params) do
    config = ensure_config(opts)

    with :ok <- expected_model(params, config.tts_model_alias),
         :ok <- backend_available(config.tts_backend.doctor(config), :text_to_speech),
         :ok <- bounded_text(text, config.max_text_bytes) do
      config.tts_backend.synthesize(text, params, config)
    end
  end

  defp ensure_config(%{base_url: _base_url} = config), do: config
  defp ensure_config(opts), do: Config.build(opts)

  defp expected_model(params, expected) do
    requested = field(params, "model")

    cond do
      not is_binary(requested) or String.trim(requested) == "" ->
        {:error, :local_voice_model_missing}

      requested == expected ->
        :ok

      true ->
        {:error, {:local_voice_model_unavailable, requested}}
    end
  end

  defp backend_available(%{available?: true}, _capability), do: :ok

  defp backend_available(%{} = doctor, capability) do
    {:error,
     {:local_voice_backend_unavailable, capability, Map.get(doctor, :diagnostic_codes, [])}}
  end

  defp bounded_text(text, max_bytes) do
    if byte_size(text) <= max_bytes do
      :ok
    else
      {:error, {:local_voice_text_too_large, byte_size(text), max_bytes}}
    end
  end

  defp models_from_doctor(config, stt, tts) do
    []
    |> maybe_add_model(stt, %{
      id: config.stt_model_alias,
      object: "model",
      owned_by: "allbert-local-runtime",
      capabilities: ["speech_to_text"]
    })
    |> maybe_add_model(tts, %{
      id: config.tts_model_alias,
      object: "model",
      owned_by: "allbert-local-runtime",
      capabilities: ["text_to_speech"]
    })
    |> Enum.reverse()
  end

  defp maybe_add_model(models, %{available?: true}, model), do: [model | models]
  defp maybe_add_model(models, _doctor, _model), do: models

  defp diagnostic_codes(stt, tts) do
    (Map.get(stt, :diagnostic_codes, []) ++ Map.get(tts, :diagnostic_codes, []))
    |> Enum.uniq()
  end

  defp field(map, "model"), do: Map.get(map, "model") || Map.get(map, :model)
end
