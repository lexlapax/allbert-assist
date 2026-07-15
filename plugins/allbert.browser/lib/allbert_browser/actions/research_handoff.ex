defmodule AllbertBrowser.Actions.ResearchHandoff do
  @moduledoc """
  Turn-level dispatcher for browser research (v1.0.1 M4.2).

  Routes browser-research intents to the real `research.specialist` delegate:
  the same objective + `delegate_agent` step machinery `mix allbert.research`
  uses (`AllbertResearch.DelegateObjective`). The action itself grants no
  browser authority — browser sessions, navigation grants, and confirmations
  stay enforced by the delegate path. When a precondition fails
  (`browser.enabled` off, `research.enabled` off, driver unavailable, delegate
  unregistered, no URL) it reports an honest non-`:completed` status naming
  the exact missing precondition instead of pretending the turn completed.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_research_handoff",
    description: "Run bounded browser research through the research.specialist delegate.",
    category: "browser",
    tags: ["browser", "intent", "handoff"],
    schema: [url: [type: :string, required: false], format: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Settings
  alias AllbertBrowser.{Actions, Doctor}
  alias AllbertResearch.DelegateObjective

  @action_name "browser_research_handoff"
  @extract_formats ["text", "html", "markdown"]

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:read_only, context)

    with :ok <- setting_enabled("browser.enabled", :browser_disabled),
         :ok <- setting_enabled("research.enabled", :research_disabled),
         :ok <- driver_available(),
         :ok <- research_agent_registered(),
         {:ok, target} <- target(params, context) do
      start_research(target, params, context, decision)
    else
      {:blocked, error, message} ->
        {:ok,
         %{
           message: message,
           status: :stopped,
           error: error,
           permission_decision: decision,
           actions: [
             Actions.action(@action_name, :stopped, :read_only, decision, %{error: error})
           ]
         }}
    end
  end

  # ── Precondition gating (honest blocked reporting, never :completed) ────────

  defp setting_enabled(key, error) do
    if Settings.get(key) == {:ok, true} do
      :ok
    else
      {:blocked, error,
       "Browser research is blocked: the `#{key}` setting is off. " <>
         "Enable it in Settings, then retry."}
    end
  end

  defp driver_available do
    case Doctor.fresh_ok?() do
      :ok ->
        :ok

      _stale_or_not_ok ->
        case Doctor.run() do
          {:ok, %{live_check_status: :ok}} ->
            :ok

          {:ok, result} ->
            status = Map.get(result, :live_check_status, :failed)
            category = Map.get(result, :error_category, :unknown_browser_doctor_error)

            {:blocked, {:browser_driver_unavailable, category},
             "Browser research is blocked: the browser driver is #{status} " <>
               "(#{category}). Run the browser doctor to diagnose the setup."}
        end
    end
  end

  defp research_agent_registered do
    registry_up? = is_pid(Process.whereis(AgentRegistry))

    with true <- registry_up?,
         {:ok, _entry} <- AgentRegistry.lookup(AllbertResearch.Runtime.agent_id()) do
      :ok
    else
      _missing ->
        {:blocked, :research_agent_unavailable,
         "Browser research is blocked: the research.specialist delegate agent is not " <>
           "registered (is the allbert.research plugin enabled?)."}
    end
  end

  # ── Target extraction ────────────────────────────────────────────────────────

  defp target(params, context) do
    url = Actions.field(params, :url)
    source_text = source_text(params, context)

    cond do
      is_binary(url) and String.trim(url) != "" ->
        {:ok, String.trim(url)}

      is_binary(found = extract_url(source_text)) ->
        {:ok, found}

      true ->
        {:blocked, :missing_research_url,
         "I need a URL to research in the browser. Tell me the site, for example: " <>
           "research https://elixir-lang.org."}
    end
  end

  defp source_text(params, context) do
    Actions.field(context, :source_text) || Actions.field(params, :text) || ""
  end

  defp extract_url(text) when is_binary(text) do
    case Regex.run(~r{https?://[^\s"'<>\)\]]+}i, text) do
      [url | _rest] -> trim_punctuation(url)
      nil -> extract_domain(text)
    end
  end

  defp extract_url(_text), do: nil

  defp extract_domain(text) do
    case Regex.run(~r/\b(?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,}\b(?:\/[^\s"'<>\)\]]*)?/i, text) do
      [domain | _rest] -> "https://" <> trim_punctuation(domain)
      nil -> nil
    end
  end

  defp trim_punctuation(value), do: String.trim_trailing(value, ".,;:!?")

  # ── Real delegate dispatch (mirrors mix allbert.research) ────────────────────

  defp start_research(target, params, context, decision) do
    user_id = user_id(params, context)

    opts =
      [
        channel: channel(context),
        source_intent: @action_name,
        trace_prefix: @action_name
      ]
      |> maybe_opt(:extract_format, extract_format(params))

    case DelegateObjective.start(user_id, target, opts) do
      {:ok, run} ->
        {:ok, response(run, target, decision)}

      {:error, reason} ->
        {:ok,
         %{
           message: "Browser research on #{target} could not start: #{inspect(reason)}.",
           status: :failed,
           error: reason,
           permission_decision: decision,
           actions: [
             Actions.action(@action_name, :failed, :read_only, decision, %{error: reason})
           ]
         }}
    end
  end

  defp response(%{status: :completed} = run, target, decision) do
    objective = run.objective

    output_data = %{
      objective_id: objective.id,
      command: run.command,
      summary: summary(run.result),
      sources: sources(run.result)
    }

    %{
      message:
        "Browser research on #{target} completed via research.specialist " <>
          "(objective #{objective.id}). Results are in the workspace Research app." <>
          summary_suffix(output_data.summary),
      status: :completed,
      objective_id: objective.id,
      output_data: output_data,
      permission_decision: decision,
      actions: [
        Actions.action(@action_name, :completed, :read_only, decision, %{
          objective_id: objective.id,
          delegate_agent_id: AllbertResearch.Runtime.agent_id(),
          command: run.command
        })
      ]
    }
  end

  defp response(%{status: :needs_confirmation} = run, target, decision) do
    objective = run.objective

    %{
      message:
        "Browser research on #{target} started as objective #{objective.id} and is " <>
          "waiting for your approval (confirmation #{run.confirmation_id}). After " <>
          "approval it resumes; results land in the workspace Research app.",
      status: :needs_confirmation,
      confirmation_id: run.confirmation_id,
      objective_id: objective.id,
      output_data: %{objective_id: objective.id, command: run.command},
      permission_decision: decision,
      actions: [
        Actions.action(@action_name, :needs_confirmation, :read_only, decision, %{
          objective_id: objective.id,
          delegate_agent_id: AllbertResearch.Runtime.agent_id(),
          command: run.command,
          confirmation_id: run.confirmation_id
        })
      ]
    }
  end

  defp response(run, target, decision) do
    objective = run.objective
    status = run.status || :failed

    %{
      message:
        "Browser research on #{target} did not complete (objective #{objective.id} " <>
          "is #{objective.status}): #{failure_summary(run.result)}",
      status: status,
      objective_id: objective.id,
      output_data: %{objective_id: objective.id, command: run.command},
      permission_decision: decision,
      actions: [
        Actions.action(@action_name, status, :read_only, decision, %{
          objective_id: objective.id,
          delegate_agent_id: AllbertResearch.Runtime.agent_id(),
          command: run.command
        })
      ]
    }
  end

  defp summary(%{delegate_response: %{summary: summary}}) when is_binary(summary), do: summary
  defp summary(%{delegate_response: %{message: message}}) when is_binary(message), do: message
  defp summary(_result), do: nil

  defp summary_suffix(nil), do: ""
  defp summary_suffix(summary), do: " #{summary}"

  defp sources(%{delegate_response: %{output_data: %{sources: sources}}}) when is_list(sources),
    do: sources

  defp sources(_result), do: []

  defp failure_summary(%{delegate_response: %{message: message}}) when is_binary(message),
    do: message

  defp failure_summary(%{message: message}) when is_binary(message), do: message
  defp failure_summary(result), do: inspect(result)

  defp user_id(params, context) do
    Actions.field(params, :user_id) ||
      Actions.field(context, :user_id) ||
      Actions.field(Actions.field(context, :request) || %{}, :user_id) ||
      "local"
  end

  defp channel(context) do
    case Actions.field(context, :channel) do
      channel when is_atom(channel) and not is_nil(channel) -> channel
      channel when is_binary(channel) and channel != "" -> channel
      _other -> :cli
    end
  end

  defp extract_format(params) do
    case Actions.field(params, :format) do
      format when format in @extract_formats -> format
      _other -> nil
    end
  end

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
