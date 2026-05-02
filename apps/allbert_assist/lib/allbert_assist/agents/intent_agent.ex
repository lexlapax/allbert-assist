defmodule AllbertAssist.Agents.IntentAgent do
  @moduledoc """
  Primary v0.01 Allbert intent agent.

  The module is a `Jido.AI.Agent` with explicit tool/action declarations, and
  it also exposes a deterministic `respond/1` function for the v0.01 runtime path.
  That keeps the first operator loop fast, testable, and conservative while the
  supervised Jido agent substrate is in place for later milestones.
  """

  use Jido.AI.Agent,
    name: "intent_agent",
    description: "Primary Allbert intent agent for the first local assistant loop.",
    model: :local,
    llm_opts: [
      provider_options: [openai_compatible_backend: :ollama]
    ],
    tools: [
      AllbertAssist.Actions.Intent.DirectAnswer,
      AllbertAssist.Actions.Intent.AppendMemory,
      AllbertAssist.Actions.Intent.ReadRecentMemory,
      AllbertAssist.Actions.Intent.ListSkills,
      AllbertAssist.Actions.Intent.ReadSkill,
      AllbertAssist.Actions.Intent.ActivateSkill,
      AllbertAssist.Actions.Intent.PlanShellCommand,
      AllbertAssist.Actions.Intent.ExternalNetworkRequest,
      AllbertAssist.Actions.Settings.ListSettings,
      AllbertAssist.Actions.Settings.ReadSetting,
      AllbertAssist.Actions.Settings.UpdateSetting,
      AllbertAssist.Actions.Settings.ExplainSetting,
      AllbertAssist.Actions.Settings.ListProviderProfiles,
      AllbertAssist.Actions.Settings.ListModelProfiles,
      AllbertAssist.Actions.Settings.SetProviderCredential
    ],
    system_prompt: """
    You are Allbert's primary v0.01 intent agent.

    Keep the runtime small and safe. Select from the named tools when an action
    is useful. Answer plainly when no action is required.

    Current boundaries:
    - You may answer directly.
    - You may list, read, or activate trusted skill declarations.
    - You may append and read markdown-backed memory for explicit memory
      requests.
    - You may append and read markdown-backed memory for low-risk personal
      identity and preference statements recognized by deterministic
      heuristics.
    - You may plan shell commands, but you must not claim to execute them.
    - You may recognize external-network requests, but you must not make them.
    - Sensitive or destructive work must be refused or marked for future
      confirmation.
    """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner

  @doc """
  Respond to one normalized runtime request.

  v0.01 currently uses deterministic routing over the same named action surface that the
  `Jido.AI.Agent` exposes as tools. Later milestones can move more of this
  selection into the supervised agent loop after permissions, memory, and
  traces are stronger.
  """
  @spec respond(map()) :: {:ok, map()} | {:error, term()}
  def respond(%{text: text} = request) when is_binary(text) do
    text = String.trim(text)
    context = %{request: request, agent: __MODULE__}

    text
    |> route()
    |> run_route(text, context)
  end

  def respond(_request), do: {:error, :missing_text}

  @doc "Return the action modules that define the v0.01 intent surface."
  def action_modules do
    Registry.modules()
  end

  defp route(text) do
    normalized = String.downcase(text)

    [
      fn -> settings_route(text, normalized) end,
      fn -> command_route(normalized) end,
      fn -> external_network_route(normalized) end,
      fn -> explicit_memory_route(normalized) end,
      fn -> personal_memory_route(text) end,
      fn -> memory_read_route(text, normalized) end,
      fn -> skill_route(text, normalized) end,
      fn -> capability_route(normalized) end
    ]
    |> Enum.find_value(:direct_answer, & &1.())
  end

  defp command_route(text), do: if(command_request?(text), do: :plan_shell_command)

  defp external_network_route(text),
    do: if(external_network_request?(text), do: :external_network_request)

  defp explicit_memory_route(text), do: if(memory_append_request?(text), do: :append_memory)

  defp personal_memory_route(text) do
    if personal_fact_statement?(text) || personal_preference_statement?(text) do
      {:append_personal_memory, personal_memory(text)}
    end
  end

  defp memory_read_route(text, normalized) do
    if memory_read_request?(normalized) || personal_recall_request?(normalized) do
      {:read_recent_memory, recall_query(text)}
    end
  end

  defp skill_route(text, normalized) do
    cond do
      activate_skill_request?(normalized) -> {:activate_skill, activate_skill_name(text)}
      read_skill_request?(normalized) -> {:read_skill, skill_name(text)}
      true -> nil
    end
  end

  defp capability_route(text), do: if(capability_request?(text), do: :list_skills)

  defp settings_route(text, normalized) do
    [
      fn -> basic_settings_route(normalized) end,
      fn -> setting_read_route(text, normalized) end,
      fn -> setting_write_route(text) end,
      fn -> provider_credential_route(text) end
    ]
    |> Enum.find_value(& &1.())
  end

  defp basic_settings_route(normalized) when normalized in ["show settings", "list settings"],
    do: :list_settings

  defp basic_settings_route(normalized) do
    if String.contains?(normalized, "show provider profiles"), do: :list_provider_profiles
  end

  defp setting_read_route(text, normalized) do
    cond do
      Regex.match?(~r/^\s*explain\s+[a-z0-9_.]+\s*$/i, text) ->
        {:explain_setting, text |> String.replace(~r/^\s*explain\s+/i, "") |> String.trim()}

      String.contains?(normalized, "timezone setting") ->
        {:read_setting, "operator.timezone"}

      Regex.match?(~r/^\s*what\s+is\s+my\s+.+\s+setting\??\s*$/i, text) ->
        {:read_setting, setting_key_from_question(text)}

      true ->
        nil
    end
  end

  defp setting_write_route(text) do
    if Regex.match?(~r/^\s*set\s+my\s+communication\s+style\s+to\s+.+/i, text) do
      {:update_setting, "operator.communication_style", value_after_to(text)}
    end
  end

  defp provider_credential_route(text) do
    cond do
      Regex.match?(~r/^\s*configure\s+my\s+openai\s+api\s+key/i, text) ->
        {:set_provider_credential, "openai", :configure}

      Regex.match?(~r/^\s*set\s+my\s+openai\s+api\s+key\s+to\s+.+/i, text) ->
        {:set_provider_credential, "openai", :raw_prompt_secret}

      Regex.match?(~r/^\s*show\s+my\s+openai\s+api\s+key/i, text) ->
        {:set_provider_credential, "openai", :raw_secret_read}

      true ->
        nil
    end
  end

  defp run_route(:plan_shell_command, text, context) do
    run_action(
      "plan_shell_command",
      %{command: requested_command(text), source_text: text},
      text,
      context
    )
  end

  defp run_route(:external_network_request, text, context) do
    run_action(
      "external_network_request",
      %{request: network_request(text), source_text: text},
      text,
      context
    )
  end

  defp run_route(:append_memory, text, context) do
    run_action("append_memory", %{memory: memory_text(text), source_text: text}, text, context)
  end

  defp run_route({:append_personal_memory, memory}, text, context) do
    run_action("append_memory", %{memory: memory, source_text: text}, text, context)
  end

  defp run_route({:read_recent_memory, query}, _text, context) do
    run_action("read_recent_memory", %{query: query}, query, context)
  end

  defp run_route({:read_skill, name}, text, context) do
    run_action("read_skill", %{name: name}, text, context, selected_skill: name)
  end

  defp run_route({:activate_skill, name}, text, context) do
    run_action("activate_skill", %{name: name}, text, context, selected_skill: name)
  end

  defp run_route(:list_skills, text, context) do
    run_action("list_skills", %{}, text, context)
  end

  defp run_route(:list_settings, text, context) do
    run_action("list_settings", %{}, text, context)
  end

  defp run_route({:read_setting, key}, text, context) do
    run_action("read_setting", %{key: key}, text, context)
  end

  defp run_route({:explain_setting, key}, text, context) do
    run_action("explain_setting", %{key: key}, text, context)
  end

  defp run_route({:update_setting, key, value}, text, context) do
    run_action("update_setting", %{key: key, value: value}, text, context)
  end

  defp run_route(:list_provider_profiles, text, context) do
    run_action("list_provider_profiles", %{}, text, context)
  end

  defp run_route({:set_provider_credential, provider, mode}, text, context) do
    run_action("set_provider_credential", %{provider: provider, mode: mode}, text, context)
  end

  defp run_route(:direct_answer, text, context) do
    run_action("direct_answer", %{text: text}, text, context)
  end

  defp run_action(action_name, params, text, context, opts \\ []) do
    runner_context =
      context
      |> Map.put(:selected_route, action_name)
      |> Map.put(:selected_action, action_name)
      |> Map.put(:source_text, text)
      |> Map.merge(Map.new(opts))

    Runner.run(action_name, params, runner_context)
  end

  defp command_request?(text) do
    Regex.match?(~r/^\s*(run|execute|exec|shell|terminal)\b/, text) ||
      String.contains?(text, " shell command") ||
      String.contains?(text, " command line") ||
      Regex.match?(~r/\brm\s+-/, text)
  end

  defp external_network_request?(text) do
    Regex.match?(
      ~r/\b(fetch|browse|download|call|post|get)\b.*\b(https?:\/\/|api|website|web|internet)\b/,
      text
    ) ||
      String.contains?(text, "http://") ||
      String.contains?(text, "https://") ||
      String.contains?(text, "external network")
  end

  defp memory_append_request?(text) do
    Regex.match?(~r/^\s*(please\s+)?remember\b/, text) ||
      Regex.match?(~r/^\s*(save|store|note)\s+(this|that)\b/, text)
  end

  defp memory_read_request?(text) do
    String.contains?(text, "what do you remember") ||
      String.contains?(text, "what did you remember") ||
      String.contains?(text, "recall") ||
      String.contains?(text, "recent memory")
  end

  defp personal_fact_statement?(text) do
    !sensitive_personal_data?(text) &&
      (identity_statement?(text) || timezone_statement?(text) ||
         working_preference_statement?(text))
  end

  defp personal_preference_statement?(text) do
    !sensitive_personal_data?(text) &&
      (communication_preference_statement?(text) || working_preference_statement?(text))
  end

  defp personal_recall_request?(text) do
    identity_recall_request?(text) ||
      preference_recall_request?(text) ||
      working_context_recall_request?(text)
  end

  defp identity_statement?(text) do
    Regex.match?(~r/^\s*my\s+name\s+is\s+\S+/i, text) ||
      Regex.match?(~r/^\s*i\s+am\s+\S+/i, text) ||
      Regex.match?(~r/^\s*i'm\s+\S+/i, text) ||
      Regex.match?(~r/^\s*call\s+me\s+\S+/i, text)
  end

  defp communication_preference_statement?(text) do
    Regex.match?(~r/^\s*i\s+prefer\s+.+/i, text) ||
      Regex.match?(~r/^\s*i\s+like\s+.+/i, text) ||
      Regex.match?(~r/^\s*please\s+keep\s+(responses|updates|answers)\s+.+/i, text) ||
      Regex.match?(~r/^\s*i\s+want\s+.+/i, text)
  end

  defp timezone_statement?(text) do
    Regex.match?(~r/^\s*my\s+time\s*zone\s+is\s+\S+/i, text) ||
      Regex.match?(~r/^\s*my\s+timezone\s+is\s+\S+/i, text)
  end

  defp working_preference_statement?(text) do
    Regex.match?(~r/^\s*i\s+usually\s+.+/i, text) ||
      Regex.match?(~r/^\s*i\s+prefer\s+.+\b(test|docs?|planning|implementation|browser)\b/i, text)
  end

  defp identity_recall_request?(text) do
    String.contains?(text, "what is my name") ||
      String.contains?(text, "who am i") ||
      String.contains?(text, "what should you call me")
  end

  defp preference_recall_request?(text) do
    String.contains?(text, "what do you know about my preferences") ||
      String.contains?(text, "how should you update me") ||
      String.contains?(text, "how should you communicate with me")
  end

  defp working_context_recall_request?(text) do
    String.contains?(text, "what timezone am i in") ||
      String.contains?(text, "what time zone am i in") ||
      String.contains?(text, "how do i like to test") ||
      String.contains?(text, "what do you remember about my planning preference")
  end

  defp sensitive_personal_data?(text) do
    Regex.match?(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, text) ||
      Regex.match?(~r/\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b/, text) ||
      Regex.match?(~r/\b\d{3}-\d{2}-\d{4}\b/, text) ||
      Regex.match?(~r/\b(password|passphrase|secret|api[_ -]?key|token|private key)\b/i, text) ||
      Regex.match?(
        ~r/\b(home address|street address|credit card|bank account|routing number)\b/i,
        text
      )
  end

  defp read_skill_request?(text) do
    String.contains?(text, "read skill") ||
      String.contains?(text, "show skill") ||
      String.contains?(text, "describe skill")
  end

  defp activate_skill_request?(text) do
    String.contains?(text, "activate skill") ||
      String.contains?(text, "use skill") ||
      String.contains?(text, "load skill")
  end

  defp capability_request?(text) do
    String.contains?(text, "what can you do") ||
      String.contains?(text, "available skills") ||
      String.contains?(text, "skills are available") ||
      String.contains?(text, "what skills") ||
      String.contains?(text, "list skills") ||
      String.contains?(text, "skills you can inspect") ||
      String.contains?(text, "capabilities") ||
      String.contains?(text, "what actions")
  end

  defp memory_text(text) do
    text
    |> String.replace(~r/^\s*(please\s+)?remember\s+(that\s+)?/i, "")
    |> String.replace(~r/^\s*(save|store|note)\s+(this|that)\s*/i, "")
    |> String.trim()
  end

  defp setting_key_from_question(text) do
    normalized = String.downcase(text)

    cond do
      String.contains?(normalized, "timezone") -> "operator.timezone"
      String.contains?(normalized, "communication style") -> "operator.communication_style"
      true -> "operator.#{normalized |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")}"
    end
  end

  defp value_after_to(text) do
    text
    |> String.replace(~r/^.*\bto\s+/i, "")
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp personal_memory(text) do
    family = personal_memory_family(text)
    extracted = personal_memory_fact(text, family)

    """
    Heuristic family: #{family}
    Inferred memory: #{extracted}
    Original statement: #{String.trim(text)}
    """
    |> String.trim()
  end

  defp personal_memory_family(text) do
    cond do
      identity_statement?(text) -> "identity.name"
      timezone_statement?(text) -> "local_context.timezone"
      working_preference_statement?(text) -> "local_context.preference"
      communication_preference_statement?(text) -> "communication.preference"
    end
  end

  defp personal_memory_fact(text, "identity.name") do
    case Regex.run(~r/^\s*(?:my\s+name\s+is|i\s+am|i'm|call\s+me)\s+(.+?)\.?\s*$/i, text) do
      [_, name] -> "Preferred name: #{String.trim(name)}"
      _match -> "Preferred name from statement"
    end
  end

  defp personal_memory_fact(text, "local_context.timezone") do
    case Regex.run(~r/^\s*my\s+(?:time\s*zone|timezone)\s+is\s+(.+?)\.?\s*$/i, text) do
      [_, timezone] -> "Timezone: #{String.trim(timezone)}"
      _match -> "Timezone from statement"
    end
  end

  defp personal_memory_fact(text, "local_context.preference") do
    "Local working preference: #{String.trim(text)}"
  end

  defp personal_memory_fact(text, "communication.preference") do
    "Communication preference: #{String.trim(text)}"
  end

  defp recall_query(text) do
    normalized = String.downcase(text)

    cond do
      identity_recall_request?(normalized) ->
        "#{text} name call me identity preferred name"

      preference_recall_request?(normalized) ->
        "#{text} preference communication update responses concise brief"

      working_context_recall_request?(normalized) ->
        "#{text} timezone time zone planning test browser docs implementation preference local context"

      true ->
        text
    end
  end

  defp requested_command(text) do
    text
    |> String.replace(~r/^\s*(please\s+)?(run|execute|exec)\s+/i, "")
    |> String.trim()
  end

  defp network_request(text) do
    text
    |> String.replace(~r/^\s*(please\s+)?(fetch|browse|download|call|post|get)\s+/i, "")
    |> String.trim()
  end

  defp skill_name(text) do
    case Regex.run(~r/(?:read|show|describe)\s+skill\s+(.+)$/i, text) do
      [_, name] -> String.trim(name)
      _match -> "list_skills"
    end
  end

  defp activate_skill_name(text) do
    case Regex.run(~r/(?:activate|use|load)\s+skill\s+(.+)$/i, text) do
      [_, name] -> String.trim(name)
      _match -> "list-skills"
    end
  end
end
