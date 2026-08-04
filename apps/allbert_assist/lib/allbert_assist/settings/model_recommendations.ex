defmodule AllbertAssist.Settings.ModelRecommendations do
  @moduledoc """
  Advisory per-purpose model recommendations for operator doctors.

  Settings Central remains the source of configured truth. This module only
  compares the current settings to the project recommendation matrix and returns
  a redacted read model for CLI/TUI/web surfaces.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelReadiness

  @statuses ~w(ok missing under-capable not-pulled unavailable remote-egress-warning)

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
      id: :direct_answer,
      purpose: "Direct answers",
      settings_key: "model_preferences.tasks.direct_answer",
      source: {:task, "direct_answer"},
      task_role: :direct_answer,
      recommended_profile: "direct_answer_local",
      recommended_model: "qwen2.5:7b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local default; another task chain is an explicit operator choice.",
      fallback:
        "Empty-chain compatibility uses the global primary; a non-empty task chain has no implicit primary fallback.",
      probe?: true
    },
    %{
      id: :fanout_manager,
      purpose: "Fan-out planning",
      settings_key: "model_preferences.tasks.fanout_manager",
      source: {:task, "fanout_manager"},
      task_role: :fanout_manager,
      recommended_profile: "direct_answer_local",
      recommended_model: "qwen2.5:7b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local default; another closed task chain is an explicit operator choice.",
      fallback: "Ordinary single-answer handling before durable fan-out framing.",
      probe?: true
    },
    %{
      id: :fanout_synthesis,
      purpose: "Fan-out report synthesis and revision",
      settings_key: "model_preferences.tasks.fanout_synthesis",
      source: {:task, "fanout_synthesis"},
      task_role: :fanout_synthesis,
      recommended_profile: "direct_answer_local",
      recommended_model: "qwen2.5:7b",
      required_capabilities: ["text_generation"],
      min_size_b: 7,
      privacy: "local default; another closed task chain is an explicit operator choice.",
      fallback: "Ordinary single-answer handling before durable fan-out framing.",
      probe?: true
    },
    %{
      id: :main_conversation,
      purpose: "Global primary / general model profile",
      settings_key: "model_preferences.primary",
      source: {:setting, "model_preferences.primary"},
      recommended_profile: "local",
      recommended_model: "llama3.2:3b",
      required_capabilities: ["text_generation"],
      min_size_b: nil,
      privacy: "operator choice",
      fallback: "Purpose-specific consumers resolve their own task preferences.",
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
    direct_answer
    fanout_manager
    fanout_synthesis
  )a

  @spec diagnose(map(), keyword()) :: map()
  def diagnose(context \\ %{}, opts \\ []) do
    Settings.with_resolved_settings(fn ->
      definitions = maybe_filter(@rows, Keyword.get(opts, :scope, :all))
      readiness = ModelReadiness.check(readiness_specs(definitions), context)
      rows = Enum.map(definitions, &row_dto(&1, Map.get(readiness, &1.id)))

      %{
        checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        statuses: @statuses,
        rows: rows,
        summary: summary(rows)
      }
    end)
  end

  @spec render(map()) :: String.t()
  def render(report) do
    summary = report.summary

    header =
      "model doctor ok=#{summary["ok"]} missing=#{summary["missing"]} " <>
        "under-capable=#{summary["under-capable"]} not-pulled=#{summary["not-pulled"]} " <>
        "unavailable=#{summary["unavailable"]} " <>
        "remote-egress-warning=#{summary["remote-egress-warning"]}"

    lines =
      report.rows
      |> Enum.map(&render_row/1)

    Enum.join([header | lines], "\n")
  end

  defp render_row(%{chain_kind: "closed_task"} = row) do
    chain = Enum.join(row.configured_profiles, ",")

    "  #{row.id} status=#{row.status} chain=[#{chain}] resolved=#{resolved_label(row)} " <>
      "unavailable-role=#{row.unavailable_role || "none"} auto-pull=#{row.auto_pull} " <>
      "key=#{row.settings_key} recommended=#{recommended_label(row)}"
  end

  defp render_row(row) do
    "  #{row.id} status=#{row.status} recommended=#{recommended_label(row)} " <>
      "configured=#{configured_label(row)} key=#{row.settings_key || "future"}"
  end

  defp maybe_filter(rows, :intent), do: Enum.filter(rows, &(&1.id in @intent_ids))
  defp maybe_filter(rows, _scope), do: rows

  defp readiness_specs(rows) do
    rows
    |> Enum.filter(& &1.probe?)
    |> Map.new(fn row -> {row.id, readiness_spec(row)} end)
  end

  defp readiness_spec(%{task_role: role}), do: {:role, role}

  defp readiness_spec(row) do
    case configured_profiles(row.source) do
      [profile | _rest] -> {:profile, profile}
      [] -> {:profile, ""}
    end
  end

  defp row_dto(%{task_role: role} = row, readiness) do
    configured_profiles = configured_profiles(row.source)
    configured_profile = List.first(configured_profiles)
    configured = resolve_profile(configured_profile)
    resolved = readiness_resolution(readiness, :unavailable_role)
    doctor = readiness_doctor(readiness)
    status = status(row, resolved, readiness)

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
      role: Atom.to_string(role),
      chain_kind: "closed_task",
      configured_profile: configured_profile,
      configured_profiles: configured_profiles,
      configured_model: configured_model(configured),
      configured_provider: configured_provider(configured),
      endpoint_kind: endpoint_kind(configured),
      resolution_status: resolution_status(resolved),
      resolved_profile: resolved_profile(resolved),
      resolved_model: configured_model(resolved),
      resolved_provider: configured_provider(resolved),
      role_readiness: status,
      unavailable_role: unavailable_role(role, status),
      auto_pull: false,
      status: status,
      diagnostics: task_role_diagnostics(row, role, resolved, doctor, status, readiness),
      doctor: public_doctor(doctor)
    })
  end

  defp row_dto(row, readiness) do
    configured_profiles = configured_profiles(row.source)
    configured_profile = List.first(configured_profiles)
    resolved = readiness_resolution(readiness, :missing_profile, configured_profile)
    doctor = readiness_doctor(readiness)
    status = status(row, resolved, readiness)

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
      diagnostics: diagnostics(row, resolved, doctor, status, readiness),
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

  defp readiness_resolution(readiness, error),
    do: readiness_resolution(readiness, error, nil)

  defp readiness_resolution(%{resolution_status: :resolved, profile: profile}, _error, _fallback)
       when is_map(profile),
       do: {:ok, profile}

  defp readiness_resolution(nil, _error, fallback) when is_binary(fallback),
    do: resolve_profile(fallback)

  defp readiness_resolution(_readiness, error, _fallback), do: {:error, error}

  defp readiness_doctor(%{doctor: doctor}) when is_map(doctor), do: {:ok, doctor}
  defp readiness_doctor(_readiness), do: nil

  defp resolution_status({:ok, _profile}), do: "resolved"
  defp resolution_status({:error, _reason}), do: "unavailable"

  defp resolved_profile({:ok, profile}), do: profile.name
  defp resolved_profile({:error, _reason}), do: nil

  defp unavailable_role(role, status)
       when status in ["missing", "under-capable", "not-pulled", "unavailable"],
       do: Atom.to_string(role)

  defp unavailable_role(_role, _status), do: nil

  defp task_role_diagnostics(
         _row,
         role,
         {:error, _reason},
         _doctor,
         _status,
         _readiness
       ),
       do: ["task role #{role} is unavailable"]

  defp task_role_diagnostics(row, _role, resolved, doctor, status, readiness) do
    diagnostics(row, resolved, doctor, status, readiness, "resolved")
  end

  defp status(%{task_role: _role}, {:error, :unavailable_role}, _readiness), do: "missing"
  defp status(_row, {:error, :missing_profile}, _readiness), do: "missing"

  defp status(row, {:ok, profile}, readiness) do
    cond do
      readiness_status(readiness) == :model_not_pulled ->
        "not-pulled"

      readiness_status(readiness) == :unavailable ->
        "unavailable"

      under_capable?(row, profile) ->
        "under-capable"

      remote?(profile) ->
        "remote-egress-warning"

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

  defp readiness_status(%{status: status}), do: status
  defp readiness_status(_readiness), do: nil

  defp diagnostics(row, resolved, doctor, status, readiness) do
    diagnostics(row, resolved, doctor, status, readiness, "configured")
  end

  defp diagnostics(row, resolved, doctor, status, readiness, subject) do
    []
    |> maybe_add(status == "missing", "#{subject} profile is missing")
    |> maybe_add(status == "under-capable", under_capable_message(row, resolved, subject))
    |> maybe_add(
      status == "not-pulled",
      "#{subject} local model was not confirmed as pulled"
    )
    |> maybe_add(status == "unavailable", unavailable_message(readiness, subject))
    |> maybe_add(
      status == "remote-egress-warning",
      "#{subject} profile uses a remote provider"
    )
    |> Kernel.++(doctor_diagnostics(doctor))
    |> Enum.uniq()
  end

  defp unavailable_message(%{reason: :endpoint_unavailable}, subject),
    do: "#{subject} local endpoint is unavailable"

  defp unavailable_message(%{reason: :credential_unavailable}, subject),
    do: "#{subject} provider credential is unavailable"

  defp unavailable_message(%{reason: :provider_disabled}, subject),
    do: "#{subject} provider is disabled"

  defp unavailable_message(%{reason: :availability_unknown}, subject),
    do: "#{subject} model availability is unknown"

  defp unavailable_message(_readiness, subject), do: "#{subject} model route is unavailable"

  defp under_capable_message(row, {:ok, profile}, subject) do
    cond do
      missing_capability?(row.required_capabilities, profile.capabilities) ->
        "#{subject} profile lacks required capability"

      below_min_size?(profile.model, row.min_size_b) ->
        "#{subject} local model is below the recommended size"

      true ->
        "#{subject} profile is under-capable"
    end
  end

  defp under_capable_message(_row, _resolved, subject),
    do: "#{subject} profile is under-capable"

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
      effective_endpoint_class: doctor.effective_endpoint_class,
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

  defp resolved_label(%{resolved_profile: nil}), do: "none"

  defp resolved_label(row) do
    "#{row.resolved_profile}(#{row.resolved_model || "unknown"})"
  end
end
