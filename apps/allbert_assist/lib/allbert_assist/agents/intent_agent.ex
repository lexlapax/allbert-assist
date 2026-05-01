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
      AllbertAssist.Actions.Intent.PlanShellCommand,
      AllbertAssist.Actions.Intent.ExternalNetworkRequest
    ],
    system_prompt: """
    You are Allbert's primary v0.01 intent agent.

    Keep the runtime small and safe. Select from the named tools when an action
    is useful. Answer plainly when no action is required.

    Current boundaries:
    - You may answer directly.
    - You may list or read v0.01 skill declarations.
    - You may select memory append/read actions, but durable markdown memory is
      not implemented until M5.
    - You may plan shell commands, but you must not claim to execute them.
    - You may recognize external-network requests, but you must not make them.
    - Sensitive or destructive work must be refused or marked for future
      confirmation.
    """

  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill

  @doc """
  Respond to one normalized runtime request.

  v0.01 currently uses deterministic routing over the same named action surface that the
  `Jido.AI.Agent` exposes as tools. Later milestones can move more of this
  selection into the supervised agent loop after permissions, memory, and
  traces are stronger.
  """
  @spec respond(%{required(:text) => String.t()}) :: {:ok, map()} | {:error, term()}
  def respond(%{text: text} = request) when is_binary(text) do
    text = String.trim(text)
    context = %{request: request, agent: __MODULE__}

    text
    |> route()
    |> run_route(text, context)
  end

  def respond(_request), do: {:error, :missing_text}

  @doc "Return the action modules that define the v0.01 M3 intent surface."
  @spec action_modules() :: [module()]
  def action_modules do
    [
      DirectAnswer,
      AppendMemory,
      ReadRecentMemory,
      ListSkills,
      ReadSkill,
      PlanShellCommand,
      ExternalNetworkRequest
    ]
  end

  defp route(text) do
    normalized = String.downcase(text)

    cond do
      command_request?(normalized) ->
        :plan_shell_command

      external_network_request?(normalized) ->
        :external_network_request

      memory_append_request?(normalized) ->
        :append_memory

      memory_read_request?(normalized) ->
        :read_recent_memory

      read_skill_request?(normalized) ->
        {:read_skill, skill_name(text)}

      capability_request?(normalized) ->
        :list_skills

      true ->
        :direct_answer
    end
  end

  defp run_route(:plan_shell_command, text, context) do
    PlanShellCommand.run(%{command: requested_command(text), source_text: text}, context)
  end

  defp run_route(:external_network_request, text, context) do
    ExternalNetworkRequest.run(%{request: network_request(text), source_text: text}, context)
  end

  defp run_route(:append_memory, text, context) do
    AppendMemory.run(%{memory: memory_text(text), source_text: text}, context)
  end

  defp run_route(:read_recent_memory, text, context) do
    ReadRecentMemory.run(%{query: text}, context)
  end

  defp run_route({:read_skill, name}, _text, context) do
    ReadSkill.run(%{name: name}, context)
  end

  defp run_route(:list_skills, _text, context) do
    ListSkills.run(%{}, context)
  end

  defp run_route(:direct_answer, text, context) do
    DirectAnswer.run(%{text: text}, context)
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

  defp read_skill_request?(text) do
    String.contains?(text, "read skill") ||
      String.contains?(text, "show skill") ||
      String.contains?(text, "describe skill")
  end

  defp capability_request?(text) do
    String.contains?(text, "what can you do") ||
      String.contains?(text, "available skills") ||
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
end
