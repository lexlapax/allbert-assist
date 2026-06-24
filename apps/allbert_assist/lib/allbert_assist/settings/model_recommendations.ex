defmodule AllbertAssist.Settings.ModelRecommendations do
  @moduledoc """
  Advisory per-purpose model recommendations for operator doctors.

  Settings Central remains the source of configured truth. This module only
  compares the current settings to the v0.56 recommendation matrix and returns a
  redacted read model for CLI/TUI/web surfaces.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelDoctor

  @statuses ~w(ok missing under-capable not-pulled remote-egress-warning)

  @rows [
    %{
      id: :intent_embedding,
      purpose: "Intent Stage-1 embedding",
      settings_key: "intent.router_embedding_profile",
      source: {:setting, "intent.router_embedding_profile"},
      recommended_profile: "embedding_local",
      recommended_model: "nomic-embed-text",
      required_capabilities: ["embeddings"],
      min_size_b: nil,
      privacy: "local-only required",
      fallback: "Prefilter returns fallback; deterministic ladder continues.",
      probe?: true
    },
    %{
      id: :intent_disambiguation,
      purpose: "Intent Stage-2 disambiguation",
      settings_key: "intent.router_model_profile",
      source: {:setting, "intent.router_model_profile"},
      recommended_profile: "router_local",
      recommended_model: "llama3.1:8b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local-first",
      fallback: "Heuristic or clarification path.",
      probe?: true
    },
    %{
      id: :intent_escalation,
      purpose: "Intent escalation",
      settings_key: "intent.router_escalation_profile",
      source: {:setting, "intent.router_escalation_profile"},
      recommended_profile: "router_escalation_local",
      recommended_model: "gemma4:26b",
      required_capabilities: ["text_generation"],
      min_size_b: 20,
      privacy: "local default; hosted escalation is explicit opt-in.",
      fallback: "Second pass falls back to clarification.",
      probe?: true
    },
    %{
      id: :descriptor_generation,
      purpose: "Descriptor generation",
      settings_key: "intent.router_model_profile",
      source: {:setting, "intent.router_model_profile"},
      recommended_profile: "router_local",
      recommended_model: "llama3.1:8b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local-only by default; hosted is opt-in and redacted.",
      fallback: "Heuristic descriptor generator.",
      probe?: false
    },
    %{
      id: :intent_eval_live_bench,
      purpose: "Intent eval live bench",
      settings_key: "intent.router_model_profile",
      source: {:setting, "intent.router_model_profile"},
      recommended_profile: "router_local",
      recommended_model: "llama3.1:8b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local",
      fallback: "Deterministic gate is model-free.",
      probe?: false
    },
    %{
      id: :main_conversation,
      purpose: "Main conversational loop",
      settings_key: "model_preferences.primary",
      source: {:setting, "model_preferences.primary"},
      recommended_profile: "local",
      recommended_model: "llama3.2:3b",
      required_capabilities: ["text_generation"],
      min_size_b: nil,
      privacy: "operator choice",
      fallback: "Graceful decline or configured provider fallback.",
      probe?: false
    },
    %{
      id: :voice_stt,
      purpose: "Voice STT",
      settings_key: "model_preferences.capabilities.speech_to_text",
      source: {:capability, "speech_to_text"},
      recommended_profile: "voice_stt_local",
      recommended_model: "whisper-local",
      required_capabilities: ["speech_to_text"],
      min_size_b: nil,
      privacy: "local default; hosted voice is audited opt-in.",
      fallback: "Voice doctor reports the gap.",
      probe?: false
    },
    %{
      id: :voice_tts,
      purpose: "Voice TTS",
      settings_key: "model_preferences.capabilities.text_to_speech",
      source: {:capability, "text_to_speech"},
      recommended_profile: "voice_tts_local",
      recommended_model: "tts-local",
      required_capabilities: ["text_to_speech"],
      min_size_b: nil,
      privacy: "local default; hosted voice is audited opt-in.",
      fallback: "Voice doctor reports the gap.",
      probe?: false
    },
    %{
      id: :vision_input,
      purpose: "Vision input",
      settings_key: "model_preferences.capabilities.vision_input",
      source: {:capability, "vision_input"},
      recommended_profile: "vision_openai",
      recommended_model: "gpt-5.2",
      required_capabilities: ["vision_input"],
      min_size_b: nil,
      privacy: "provider choice; image traces remain redacted.",
      fallback: "Provider doctor reports the gap.",
      probe?: false
    },
    %{
      id: :image_generation,
      purpose: "Image generation",
      settings_key: "model_preferences.capabilities.image_generation",
      source: {:capability, "image_generation"},
      recommended_profile: "image_openai",
      recommended_model: "gpt-image-1.5",
      required_capabilities: ["image_generation"],
      min_size_b: nil,
      privacy: "provider choice; image traces remain redacted.",
      fallback: "Provider doctor reports the gap.",
      probe?: false
    },
    %{
      id: :codegen_committee,
      purpose: "Codegen committee",
      settings_key: "model_preferences.tasks.coding",
      source: {:task, "coding"},
      recommended_profile: "coding_local",
      recommended_model: "qwen2.5-coder:7b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "sandboxed and gated",
      fallback: "Gate report blocks unsafe integration.",
      probe?: false
    },
    %{
      id: :advisory_critics,
      purpose: "Advisory critics / LLM judge",
      settings_key: "model_preferences.tasks.coding",
      source: {:task, "coding"},
      recommended_profile: "capable",
      recommended_model: "claude-sonnet-4-6",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "advisory only; hosted is audited opt-in.",
      fallback: "Advisory output is dropped.",
      probe?: false
    },
    %{
      id: :pi_mode_coding,
      purpose: "Pi-mode coding (v0.57)",
      settings_key: "coding.model_profile",
      source: {:setting, "coding.model_profile"},
      recommended_profile: "pi_coding_local",
      recommended_model: "qwen2.5:7b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local/private coding with real provider tool-call chunks",
      fallback: "Switch to a streaming/tool-call-capable profile.",
      probe?: true
    }
  ]

  @intent_ids ~w(
    intent_embedding
    intent_disambiguation
    intent_escalation
    descriptor_generation
    intent_eval_live_bench
  )a

  @spec diagnose(map(), keyword()) :: map()
  def diagnose(context \\ %{}, opts \\ []) do
    rows =
      @rows
      |> maybe_filter(Keyword.get(opts, :scope, :all))
      |> Enum.map(&row_dto(&1, context))

    %{
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      statuses: @statuses,
      rows: rows,
      summary: summary(rows)
    }
  end

  @spec render(map()) :: String.t()
  def render(report) do
    summary = report.summary

    header =
      "model doctor ok=#{summary["ok"]} missing=#{summary["missing"]} " <>
        "under-capable=#{summary["under-capable"]} not-pulled=#{summary["not-pulled"]} " <>
        "remote-egress-warning=#{summary["remote-egress-warning"]}"

    lines =
      report.rows
      |> Enum.map(fn row ->
        "  #{row.id} status=#{row.status} recommended=#{recommended_label(row)} " <>
          "configured=#{configured_label(row)} key=#{row.settings_key || "future"}"
      end)

    Enum.join([header | lines], "\n")
  end

  defp maybe_filter(rows, :intent), do: Enum.filter(rows, &(&1.id in @intent_ids))
  defp maybe_filter(rows, _scope), do: rows

  defp row_dto(row, context) do
    configured_profiles = configured_profiles(row.source)
    configured_profile = List.first(configured_profiles)
    resolved = resolve_profile(configured_profile)
    doctor = maybe_doctor(row, resolved, context)
    status = status(row, resolved, doctor)

    row
    |> Map.take([
      :id,
      :purpose,
      :settings_key,
      :recommended_profile,
      :recommended_model,
      :required_capabilities,
      :min_size_b,
      :privacy,
      :fallback
    ])
    |> Map.merge(%{
      id: Atom.to_string(row.id),
      configured_profile: configured_profile,
      configured_profiles: configured_profiles,
      configured_model: configured_model(resolved),
      configured_provider: configured_provider(resolved),
      endpoint_kind: endpoint_kind(resolved),
      status: status,
      diagnostics: diagnostics(row, resolved, doctor, status),
      doctor: public_doctor(doctor)
    })
  end

  defp configured_profiles({:setting, key}) do
    key
    |> setting_value()
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp configured_profiles({:capability, capability}) do
    configured_profiles({:setting, "model_preferences.capabilities.#{capability}"})
  end

  defp configured_profiles({:task, task}) do
    configured_profiles({:setting, "model_preferences.tasks.#{task}"})
  end

  defp setting_value(key) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp resolve_profile(nil), do: {:error, :missing_profile}

  defp resolve_profile(profile) do
    case Settings.resolve_model_profile(profile) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, :missing_profile}
    end
  end

  defp maybe_doctor(
         %{probe?: true},
         {:ok, %{provider_endpoint_kind: "local_endpoint"}} = resolved,
         context
       ) do
    {:ok, profile} = resolved

    case ModelDoctor.diagnose(profile.name, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_doctor(_row, _resolved, _context), do: nil

  defp status(_row, {:error, :missing_profile}, _doctor), do: "missing"

  defp status(row, {:ok, profile}, doctor) do
    cond do
      under_capable?(row, profile) ->
        "under-capable"

      remote?(profile) ->
        "remote-egress-warning"

      not_pulled?(doctor) ->
        "not-pulled"

      true ->
        "ok"
    end
  end

  defp under_capable?(row, profile) do
    missing_capability?(row.required_capabilities, profile.capabilities) ||
      below_min_size?(profile.model, row.min_size_b)
  end

  defp missing_capability?([], _capabilities), do: false

  defp missing_capability?(required, capabilities) do
    required = MapSet.new(required)
    capabilities = MapSet.new(List.wrap(capabilities))
    not MapSet.subset?(required, capabilities)
  end

  defp below_min_size?(_model, nil), do: false

  defp below_min_size?(model, min_size_b) do
    case model_size_b(model) do
      nil -> false
      size -> size < min_size_b
    end
  end

  defp model_size_b(model) when is_binary(model) do
    case Regex.run(~r/(?:^|[:\-_])(\d+(?:\.\d+)?)b(?:$|[\-_:])?/i, model) do
      [_match, size] -> parse_float(size)
      _other -> nil
    end
  end

  defp model_size_b(_model), do: nil

  defp parse_float(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> nil
    end
  end

  defp remote?(%{provider_endpoint_kind: "credentialed_remote"}), do: true
  defp remote?(_profile), do: false

  defp not_pulled?({:ok, doctor}) when doctor.model_available in [false, :unknown], do: true
  defp not_pulled?(_doctor), do: false

  defp diagnostics(row, resolved, doctor, status) do
    []
    |> maybe_add(status == "missing", "configured profile is missing")
    |> maybe_add(status == "under-capable", under_capable_message(row, resolved))
    |> maybe_add(status == "not-pulled", "configured local model was not confirmed as pulled")
    |> maybe_add(status == "remote-egress-warning", "configured profile uses a remote provider")
    |> Kernel.++(doctor_diagnostics(doctor))
    |> Enum.uniq()
  end

  defp under_capable_message(row, {:ok, profile}) do
    cond do
      missing_capability?(row.required_capabilities, profile.capabilities) ->
        "configured profile lacks required capability"

      below_min_size?(profile.model, row.min_size_b) ->
        "configured local model is below the recommended size"

      true ->
        "configured profile is under-capable"
    end
  end

  defp under_capable_message(_row, _resolved), do: "configured profile is under-capable"

  defp maybe_add(items, true, item), do: [item | items]
  defp maybe_add(items, false, _item), do: items

  defp doctor_diagnostics({:ok, doctor}) do
    doctor
    |> Map.get(:diagnostics, [])
    |> Enum.map(&Map.get(&1, :code))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Atom.to_string/1)
  end

  defp doctor_diagnostics(_doctor), do: []

  defp public_doctor({:ok, doctor}) do
    %{
      endpoint_kind: doctor.endpoint_kind,
      endpoint_ok: doctor.endpoint_ok,
      model_available: doctor.model_available,
      context_window: doctor.context_window,
      diagnostics: doctor_diagnostics({:ok, doctor})
    }
  end

  defp public_doctor(_doctor), do: nil

  defp configured_model({:ok, profile}), do: profile.model
  defp configured_model(_resolved), do: nil

  defp configured_provider({:ok, profile}), do: profile.provider
  defp configured_provider(_resolved), do: nil

  defp endpoint_kind({:ok, profile}), do: profile.provider_endpoint_kind
  defp endpoint_kind(_resolved), do: nil

  defp summary(rows) do
    counts = Enum.frequencies_by(rows, & &1.status)
    Map.new(@statuses, &{&1, Map.get(counts, &1, 0)})
  end

  defp recommended_label(%{recommended_profile: nil, recommended_model: model}), do: model

  defp recommended_label(row) do
    "#{row.recommended_profile}(#{row.recommended_model})"
  end

  defp configured_label(%{configured_profile: nil}), do: "none"

  defp configured_label(row) do
    "#{row.configured_profile}(#{row.configured_model || "unknown"})"
  end
end
