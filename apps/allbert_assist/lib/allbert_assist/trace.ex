defmodule AllbertAssist.Trace do
  @moduledoc """
  Markdown trace recorder for v0.01 runtime turns.

  M6 keeps traces plain and inspectable. The trace store writes markdown through
  `AllbertAssist.Memory` so the user can read, move, or delete trace files with
  ordinary filesystem tools.
  """

  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Memory
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Workspace

  @model_alias :local
  @workspace_recent_limit 5

  @type result :: {:ok, Memory.entry()} | {:disabled, :tracing_disabled} | {:error, term()}

  @doc "Return true when runtime trace recording is enabled."
  @spec enabled?() :: boolean()
  def enabled?(turn \\ %{}) do
    request_trace_enabled?(turn) || env_enabled?() || config_enabled?() || settings_enabled?(turn)
  end

  @doc "Record one runtime turn as markdown when tracing is enabled."
  @spec record_turn(map()) :: result()
  def record_turn(turn) when is_map(turn) do
    if enabled?(turn) do
      do_record_turn(turn)
    else
      {:disabled, :tracing_disabled}
    end
  end

  def record_turn(_turn), do: {:error, :invalid_trace_turn}

  @doc "Render one runtime turn as inspectable markdown trace text."
  @spec text(map()) :: String.t()
  def text(turn) when is_map(turn), do: trace_body(turn)

  defp do_record_turn(turn) do
    writer().(trace_attrs(turn))
  rescue
    exception ->
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp writer do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:writer, &Memory.append/1)
  end

  defp config_enabled? do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  defp env_enabled? do
    System.get_env("ALLBERT_TRACE_ENABLED") in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]
  end

  defp request_trace_enabled?(turn) do
    request = Map.get(turn, :request, %{})
    metadata = Map.get(request, :metadata, %{})

    Map.get(request, :trace) in [true, "true", "1"] ||
      Map.get(metadata, :trace) in [true, "true", "1"] ||
      Map.get(metadata, "trace") in [true, "true", "1"]
  end

  defp settings_enabled?(turn) do
    case AllbertAssist.Settings.get("runtime.trace_default") do
      {:ok, "enabled"} -> true
      {:ok, "denied_only"} -> denied_or_confirmation?(turn)
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp denied_or_confirmation?(turn) do
    status =
      turn
      |> Map.get(:response, %{})
      |> Map.get(:status)

    status in [:denied, :needs_confirmation]
  end

  defp trace_attrs(turn) do
    response = Map.fetch!(turn, :response)
    input_signal = Map.fetch!(turn, :input_signal)
    response_signal = Map.fetch!(turn, :response_signal)
    request = Map.fetch!(turn, :request)

    %{
      category: :traces,
      summary: trace_summary(response, input_signal),
      body: text(turn),
      source_signal_id: input_signal.id,
      actor: Map.get(request, :user_id, Map.get(request, :operator_id, "local")),
      agent: inspect(Map.get(turn, :agent, AllbertAssist.Agents.IntentAgent)),
      channel: Map.get(request, :channel, "unknown"),
      response_signal_id: response_signal.id
    }
  end

  defp trace_summary(response, input_signal) do
    action_name =
      response
      |> Map.get(:actions, [])
      |> List.first()
      |> action_name()

    "#{response.status} #{action_name} #{input_signal.id}"
  end

  defp trace_body(turn) do
    request = Map.fetch!(turn, :request)
    input_signal = Map.fetch!(turn, :input_signal)
    response_signal = Map.fetch!(turn, :response_signal)
    response = Map.fetch!(turn, :response)
    workspace = workspace_trace(turn)

    """
    ## Runtime Turn

    - Trace format: v0.01-m6
    - Input signal: #{input_signal.id}
    - Input signal type: #{input_signal.type}
    - Response signal: #{response_signal.id}
    - Response signal type: #{response_signal.type}
    - Channel: #{request.channel}
    - User: #{Map.get(request, :user_id, request.operator_id)}
    - Operator: #{request.operator_id}
    - Thread: #{Map.get(request, :thread_id, "none")}
    - Session: #{Map.get(request, :session_id, "none") || "none"}
    #{active_app_trace_line(request)}    - Agent: #{inspect(Map.get(turn, :agent, AllbertAssist.Agents.IntentAgent))}
    - Model alias: #{model_alias()}
    - Status: #{response.status}
    - Selected action: #{selected_action(response.actions)}
    - Intent decision: #{intent_decision_summary(response)}
    - Permission decision: #{permission_decision(response.actions)}
    - Security metadata: #{security_metadata_summary(response.actions)}
    - Settings metadata: #{settings_metadata(response.actions)}
    - Confirmation metadata: #{confirmation_metadata_summary(response.actions)}
    - External request metadata: #{external_request_metadata_summary(response.actions)}
    - Package install metadata: #{package_install_metadata_summary(response.actions)}
    - Online skill metadata: #{online_skill_metadata_summary(response.actions)}
    - Resource metadata: #{resource_metadata_summary(response.actions)}
    - Shell command metadata: #{shell_command_metadata_summary(response.actions)}
    - Skill metadata: #{skill_metadata_summary(response.actions)}
    - Token estimate: #{token_estimate(request.text, response.message)}
    - Cost estimate: unavailable-local-model

    ## Input

    #{request.text}

    ## Response

    #{response.message}
    #{objective_inline(response)}
    #{workspace_inline(workspace)}

    ## Actions

    ```elixir
    #{inspect(Redactor.redact(response.actions), pretty: true, limit: :infinity)}
    ```
    #{objective_inline(response)}

    ## Intent Decision

    #{intent_decision_text(response)}

    ## Intent Candidates

    #{intent_candidates_text(response)}

    ## Memory Review

    #{memory_review_text(response.actions)}

    ## Resource Access

    #{intent_resource_access_text(response)}

    ## Skill Metadata

    #{skill_metadata_text(response.actions)}

    ## Security Metadata

    #{security_metadata_text(response.actions)}

    ## Confirmation Metadata

    #{confirmation_metadata_text(response.actions)}
    #{objective_inline(response)}

    ## External Request Metadata

    #{external_request_metadata_text(response.actions)}

    ## Package Install Metadata

    #{package_install_metadata_text(response.actions)}

    ## Online Skill Metadata

    #{online_skill_metadata_text(response.actions)}

    ## Resource Metadata

    #{resource_metadata_text(response.actions)}

    ## Shell Command Metadata

    #{shell_command_metadata_text(response.actions)}

    ## StockSage Analysis

    #{stocksage_analysis_text(response.actions)}
    #{objective_inline(response)}

    ## StockSage Native Analysis

    #{stocksage_native_analysis_text(response.actions)}

    ## Objective Steps

    #{objective_steps_text(response)}

    ## Workspace

    #{workspace_text(workspace)}

    ## Diagnostics

    #{diagnostics_text(response)}
    #{AllbertAssist.JidoBacked.debug_trace_markdown()}
    """
    |> String.trim()
  end

  defp model_alias do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:model_alias, @model_alias)
  end

  defp selected_action(actions) do
    actions
    |> List.first()
    |> action_name()
  end

  defp active_app_trace_line(%{active_app: active_app}) when not is_nil(active_app) do
    "    - Active app: #{active_app}\n"
  end

  defp active_app_trace_line(_request), do: ""

  defp action_name(%{name: name}) when is_binary(name), do: name
  defp action_name(%{"name" => name}) when is_binary(name), do: name
  defp action_name(_action), do: "none"

  defp permission_decision(actions) do
    actions
    |> List.first()
    |> case do
      %{permission_decision: decision} -> inspect(Redactor.redact(decision), pretty: true)
      %{"permission_decision" => decision} -> inspect(Redactor.redact(decision), pretty: true)
      _action -> "none"
    end
  end

  defp security_metadata_summary(actions) do
    actions
    |> security_decision()
    |> case do
      %{decision: decision, risk: %{tier: risk}, trace: %{policy_source: source}} ->
        "#{decision} risk=#{risk} policy=#{source}"

      %{decision: decision} ->
        "#{decision}"

      _decision ->
        "none"
    end
  end

  defp security_metadata_text(actions) do
    actions
    |> security_decision()
    |> case do
      nil ->
        "none"

      decision ->
        decision
        |> Map.take([
          :permission,
          :decision,
          :requires_confirmation,
          :reason,
          :risk,
          :policy,
          :trace,
          :trust_boundary,
          :audit
        ])
        |> Redactor.redact()
        |> inspect(pretty: true, limit: :infinity)
    end
  end

  defp security_decision(actions) do
    actions
    |> List.first()
    |> case do
      %{permission_decision: %{risk: _risk} = decision} ->
        decision

      %{"permission_decision" => %{"risk" => _risk} = decision} ->
        atomize_security_decision(decision)

      _action ->
        nil
    end
  end

  defp atomize_security_decision(%{} = decision) do
    Map.new(decision, fn {key, value} -> {atomize_key(key), atomize_nested(value)} end)
  end

  defp atomize_nested(%{} = map), do: atomize_security_decision(map)
  defp atomize_nested(list) when is_list(list), do: Enum.map(list, &atomize_nested/1)
  defp atomize_nested(value), do: value

  defp atomize_key(key) when is_atom(key), do: key
  defp atomize_key("requires_confirmation"), do: :requires_confirmation
  defp atomize_key("trust_boundary"), do: :trust_boundary
  defp atomize_key("permission"), do: :permission
  defp atomize_key("decision"), do: :decision
  defp atomize_key("reason"), do: :reason
  defp atomize_key("risk"), do: :risk
  defp atomize_key("policy"), do: :policy
  defp atomize_key("trace"), do: :trace
  defp atomize_key("audit"), do: :audit
  defp atomize_key(key), do: key

  defp settings_metadata(actions) do
    actions
    |> List.first()
    |> case do
      %{settings_metadata: metadata} -> inspect(metadata, pretty: true)
      %{"settings_metadata" => metadata} -> inspect(metadata, pretty: true)
      _action -> "none"
    end
  end

  defp confirmation_metadata_summary(actions) do
    action = List.first(actions)

    case confirmation_metadata(action) do
      nil -> "none"
      metadata -> confirmation_summary(action, metadata)
    end
  end

  defp confirmation_summary(action, metadata) do
    id = map_value(metadata, :id) || map_value(action, :confirmation_id)
    status = map_value(metadata, :status) || map_value(metadata, :confirmation_status)
    target = map_value(metadata, :target_action) || action_name(action)
    origin = map_value(metadata, :origin) || %{}

    "#{id} status=#{status || "unknown"} target=#{target || "unknown"} origin=#{map_value(origin, :channel) || "unknown"}"
  end

  defp confirmation_metadata_text(actions) do
    action = List.first(actions)

    case confirmation_metadata(action) do
      nil ->
        "none"

      metadata ->
        %{
          confirmation_id: map_value(action, :confirmation_id),
          confirmation_metadata: metadata
        }
        |> Redactor.redact()
        |> inspect(pretty: true, limit: :infinity)
    end
  end

  defp confirmation_metadata(%{confirmation_metadata: metadata}) when not is_nil(metadata),
    do: metadata

  defp confirmation_metadata(%{"confirmation_metadata" => metadata}) when not is_nil(metadata),
    do: metadata

  defp confirmation_metadata(%{confirmation_id: id}) when not is_nil(id), do: %{id: id}
  defp confirmation_metadata(%{"confirmation_id" => id}) when not is_nil(id), do: %{"id" => id}
  defp confirmation_metadata(_action), do: nil

  defp external_request_metadata_summary(actions) do
    actions
    |> List.first()
    |> ExternalRequestMetadata.action_lines()
    |> first_line_or_none()
  end

  defp external_request_metadata_text(actions) do
    actions
    |> List.first()
    |> ExternalRequestMetadata.action_lines()
    |> lines_or_none()
  end

  defp package_install_metadata_summary(actions) do
    actions
    |> List.first()
    |> PackageInstallMetadata.action_lines()
    |> first_line_or_none()
  end

  defp package_install_metadata_text(actions) do
    actions
    |> List.first()
    |> PackageInstallMetadata.action_lines()
    |> lines_or_none()
  end

  defp online_skill_metadata_summary(actions) do
    actions
    |> List.first()
    |> OnlineSkillMetadata.action_lines()
    |> first_line_or_none()
  end

  defp online_skill_metadata_text(actions) do
    actions
    |> List.first()
    |> OnlineSkillMetadata.action_lines()
    |> lines_or_none()
  end

  defp shell_command_metadata_summary(actions) do
    actions
    |> List.first()
    |> ShellCommandMetadata.action_lines()
    |> first_line_or_none()
  end

  defp shell_command_metadata_text(actions) do
    actions
    |> List.first()
    |> ShellCommandMetadata.action_lines()
    |> lines_or_none()
  end

  defp resource_metadata_summary(actions) do
    actions
    |> List.first()
    |> ResourceMetadata.action_lines()
    |> first_line_or_none()
  end

  defp resource_metadata_text(actions) do
    actions
    |> List.first()
    |> ResourceMetadata.action_lines()
    |> lines_or_none()
  end

  defp first_line_or_none(lines) do
    case lines do
      [] -> "none"
      [line | _rest] -> line
    end
  end

  defp lines_or_none(lines) do
    lines
    |> case do
      [] -> "none"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp skill_metadata_summary(actions) do
    actions
    |> skill_metadata()
    |> case do
      %{selected_skill: selected_skill, source_scope: source_scope, trust_status: trust_status} ->
        "#{selected_skill} (#{source_scope}, #{trust_status})"

      %{selected_skill: selected_skill, status: status} ->
        "#{selected_skill} (#{status})"

      _metadata ->
        "none"
    end
  end

  defp skill_metadata_text(actions) do
    actions
    |> skill_metadata()
    |> case do
      nil -> "none"
      metadata -> inspect(metadata, pretty: true, limit: :infinity)
    end
  end

  defp skill_metadata(actions) do
    actions
    |> List.first()
    |> case do
      %{skill_metadata: metadata} -> metadata
      %{"skill_metadata" => metadata} -> metadata
      _action -> nil
    end
  end

  defp token_estimate(input, output) do
    [input, output]
    |> Enum.map(&estimate_text_tokens/1)
    |> Enum.sum()
  end

  defp estimate_text_tokens(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp estimate_text_tokens(_text), do: 0

  defp diagnostics_text(%{diagnostics: []}), do: "none"
  defp diagnostics_text(%{diagnostics: diagnostics}), do: inspect(diagnostics, pretty: true)
  defp diagnostics_text(_response), do: "none"

  defp stocksage_analysis_text(actions) do
    case stocksage_run_analysis_action(actions) do
      nil ->
        "none"

      action ->
        metadata = stocksage_action_metadata(action)

        # v0.22 audit closeout (Gap 1 — stub-mode visibility): always render
        # `Stub:` line so operator trace inspection makes the data source
        # obvious. `true` means the bridge ran in `force_stub: true` mode
        # (no real TradingAgents propagate call); `false` means a real run.
        [
          "- Action: run_analysis",
          "- Status: #{Map.get(action, :status)}",
          "- Ticker: #{stocksage_field(metadata, :ticker)}",
          "- Analysis date: #{stocksage_field(metadata, :analysis_date)}",
          "- Engine: #{stocksage_field(metadata, :engine)}",
          "- Analysis id: #{stocksage_field(metadata, :analysis_id) || stocksage_field(metadata, :confirmation_id)}",
          "- Bridge duration ms: #{stocksage_field(metadata, :bridge_duration_ms)}",
          "- Truncated: #{stocksage_field(metadata, :truncated)}",
          "- Stub: #{stocksage_stub_field(metadata)}",
          "- Queue entry id: #{stocksage_field(metadata, :queue_entry_id)}",
          "- Summary: #{bounded_summary(stocksage_field(metadata, :summary))}"
        ]
        |> Enum.join("\n")
    end
  end

  defp stocksage_stub_field(metadata) do
    case stocksage_field(metadata, :stub) do
      nil -> "false"
      true -> "true"
      false -> "false"
      other -> inspect(other)
    end
  end

  defp stocksage_run_analysis_action(actions) do
    Enum.find(actions, fn action ->
      Map.get(action, :name) == "run_analysis" or Map.get(action, "name") == "run_analysis"
    end)
  end

  defp stocksage_action_metadata(action) do
    Map.get(action, :stocksage, %{}) || Map.get(action, "stocksage", %{})
  end

  defp stocksage_native_analysis_text(actions) do
    with action when not is_nil(action) <- stocksage_run_analysis_action(actions),
         metadata <- stocksage_action_metadata(action),
         engine when engine in ["native", "both"] <- stocksage_field(metadata, :engine),
         native_trace when is_map(native_trace) <- stocksage_field(metadata, :native_trace) do
      [
        stocksage_native_summary(metadata, native_trace),
        stocksage_native_agent_table(native_trace),
        stocksage_native_debate_rounds(native_trace),
        stocksage_native_parity(native_trace)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")
    else
      _other -> "none"
    end
  end

  defp stocksage_native_summary(metadata, native_trace) do
    agent_count =
      native_trace
      |> map_value(:agent_reports)
      |> List.wrap()
      |> length()

    modes =
      native_trace
      |> map_value(:generation_modes)
      |> List.wrap()
      |> Enum.join(", ")
      |> case do
        "" -> "deterministic_advisory"
        value -> value
      end

    [
      "- Engine: #{stocksage_field(metadata, :engine)}",
      "- Native agents: #{agent_count}",
      "- Generation mode: #{modes}",
      "- Execution posture: bounded advisory packets through native specialist agents",
      "- Analysis id: #{stocksage_field(metadata, :analysis_id)}"
    ]
    |> Enum.join("\n")
  end

  defp stocksage_native_agent_table(native_trace) do
    rows =
      native_trace
      |> map_value(:agent_reports)
      |> List.wrap()
      |> Enum.take(12)
      |> Enum.map(&stocksage_native_agent_row/1)

    case rows do
      [] ->
        ""

      rows ->
        [
          "| Agent | Status | Confidence | Mode | Summary |",
          "|---|---:|---:|---|---|"
          | rows
        ]
        |> Enum.join("\n")
    end
  end

  defp stocksage_native_agent_row(report) do
    [
      map_value(report, :agent_id),
      map_value(report, :status),
      map_value(report, :confidence),
      map_value(report, :generation_mode),
      bounded_summary(map_value(report, :summary))
    ]
    |> Enum.map(&markdown_cell/1)
    |> then(&"| #{Enum.join(&1, " | ")} |")
  end

  defp stocksage_native_debate_rounds(native_trace) do
    rounds =
      native_trace
      |> map_value(:debate_rounds)
      |> List.wrap()
      |> Enum.take(5)

    case rounds do
      [] ->
        ""

      rounds ->
        [
          "Debate rounds:"
          | Enum.map(rounds, fn round ->
              "- Round #{map_value(round, :round_index) || "?"}: bull=#{bounded_summary(map_value(round, :bull_summary))}; bear=#{bounded_summary(map_value(round, :bear_summary))}; risk_reviews=#{map_value(round, :risk_count) || 0}"
            end)
        ]
        |> Enum.join("\n")
    end
  end

  defp stocksage_native_parity(native_trace) do
    case map_value(native_trace, :parity_diff) do
      parity when is_map(parity) ->
        [
          "Parity diff:",
          "- Native rating: #{map_value(parity, :native_rating) || "none"}",
          "- Python rating: #{map_value(parity, :python_rating) || "none"}",
          "- Rating agreement: #{map_value(parity, :rating_agreement) || "none"}",
          "- Confidence delta: #{map_value(parity, :confidence_delta) || "none"}",
          "- Pass: #{map_value(parity, :parity_pass) || false}"
        ]
        |> Enum.join("\n")

      _other ->
        ""
    end
  end

  defp markdown_cell(nil), do: "-"

  defp markdown_cell(value) do
    value
    |> bounded_summary()
    |> String.replace("|", "\\|")
    |> String.replace("\n", " ")
  end

  defp stocksage_field(metadata, key) when is_map(metadata) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp stocksage_field(_metadata, _key), do: nil

  defp bounded_summary(nil), do: "-"

  defp bounded_summary(value) when is_binary(value) do
    if byte_size(value) > 200, do: binary_part(value, 0, 200), else: value
  end

  defp bounded_summary(value), do: inspect(value)

  defp objective_inline(response) do
    case objective_context(response) do
      nil ->
        ""

      objective ->
        """

        ### Objective

        - Objective: #{map_value(objective, :title) || map_value(objective, :id)}
        - Objective id: #{map_value(objective, :id)}
        - Status: #{map_value(objective, :status)}
        - Step count: #{map_value(objective, :step_count) || length(List.wrap(map_value(objective, :steps)))}
        """
    end
  end

  defp objective_steps_text(response) do
    case objective_context(response) do
      nil -> "none"
      objective -> objective_steps_text_for(objective)
    end
  end

  defp objective_steps_text_for(objective) do
    objective
    |> map_value(:steps)
    |> List.wrap()
    |> Enum.take(5)
    |> case do
      [] -> objective_without_steps_text(objective)
      steps -> Enum.map_join(steps, "\n", &objective_step_text/1)
    end
  end

  defp objective_without_steps_text(objective) do
    "- Objective: #{map_value(objective, :id)} status=#{map_value(objective, :status)} steps=#{map_value(objective, :step_count) || 0}"
  end

  defp objective_step_text(step) do
    "- Step: #{map_value(step, :id) || "unknown"} status=#{map_value(step, :status) || "unknown"} kind=#{map_value(step, :kind) || "unknown"} action=#{map_value(step, :candidate_action) || "none"} confirmation=#{map_value(step, :confirmation_id) || "none"}"
  end

  defp objective_context(response) do
    map_value(response, :objective) ||
      response
      |> map_value(:actions)
      |> List.wrap()
      |> Enum.find_value(&action_objective_context/1)
  end

  defp action_objective_context(action) do
    case map_value(action, :objective_id) do
      nil ->
        stocksage = map_value(action, :stocksage) || %{}

        case map_value(stocksage, :objective_id) do
          nil -> nil
          id -> %{id: id, status: "unknown", step_count: 0}
        end

      id ->
        %{id: id, status: map_value(action, :status) || "unknown", step_count: 0}
    end
  end

  defp intent_decision_summary(response) do
    case map_value(response, :decision) do
      nil ->
        "none"

      decision ->
        selected_action = map_value(decision, :selected_action) || "none"
        confirmation = map_value(decision, :confirmation) || "unknown"
        permission = map_value(decision, :permission) || "unknown"
        "#{selected_action} permission=#{permission} confirmation=#{confirmation}"
    end
  end

  defp intent_decision_text(response) do
    case map_value(response, :decision) do
      nil ->
        "none"

      decision ->
        decision
        |> Redactor.redact()
        |> inspect(pretty: true, limit: :infinity)
    end
  end

  defp intent_candidates_text(response) do
    candidates =
      response
      |> map_value(:decision)
      |> map_value(:trace_metadata)
      |> map_value(:intent_candidates)

    case candidates do
      nil ->
        "none"

      candidates ->
        selected = map_value(candidates, :selected)
        rejected = candidates |> map_value(:rejected) |> List.wrap() |> Enum.take(5)
        memory = candidates |> map_value(:memory) |> List.wrap() |> Enum.take(5)

        """
        Active app: #{response |> map_value(:decision) |> map_value(:trace_metadata) |> map_value(:active_app) || "none"}
        Surface target: #{bounded_inspect(response |> map_value(:decision) |> map_value(:trace_metadata) |> map_value(:surface_target))}
        Classifier: #{bounded_inspect(response |> map_value(:decision) |> map_value(:trace_metadata) |> map_value(:classifier))}
        Selected: #{candidate_line(selected)}
        Memory:
        #{memory_lines(memory)}
        Rejected:
        #{rejected_lines(rejected)}
        """
        |> String.trim()
    end
  end

  defp candidate_line(nil), do: "none"

  defp candidate_line(candidate) do
    "#{map_value(candidate, :kind)}/#{map_value(candidate, :id)} score=#{map_value(candidate, :score)} reason=#{map_value(candidate, :reason) || "none"}"
  end

  defp rejected_lines([]), do: "none"

  defp rejected_lines(rejected) do
    rejected
    |> Enum.map(&"- #{candidate_line(&1)}")
    |> Enum.join("\n")
  end

  defp memory_lines([]), do: "none"

  defp memory_lines(candidates) do
    candidates
    |> Enum.map(fn candidate ->
      trace = map_value(candidate, :trace_metadata) || %{}

      "- #{candidate_line(candidate)} category=#{map_value(trace, :category) || "unknown"} review_status=#{map_value(trace, :review_status) || "unknown"} timestamp=#{map_value(trace, :timestamp) || "unknown"} path=#{map_value(trace, :path) || "unknown"}"
    end)
    |> Enum.join("\n")
  end

  defp memory_review_text(actions) do
    actions
    |> List.wrap()
    |> Enum.filter(&memory_review_action?/1)
    |> Enum.map(&memory_review_line/1)
    |> case do
      [] -> "none"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp memory_review_action?(action) do
    action_name(action) in [
      "review_memory_entry",
      "update_memory_entry",
      "delete_memory_entry",
      "prune_memory_entries",
      "promote_conversation_turn",
      "compile_memory_index",
      "summarize_memory_category"
    ]
  end

  defp memory_review_line(action) do
    "- #{action_name(action)} status=#{memory_action_value(action, :status, "unknown")} execution=#{memory_action_value(action, :execution, "none")} path=#{memory_action_path(action)} category=#{memory_action_value(action, :memory_category, "unknown")} review_status=#{memory_action_value(action, :review_status, "unknown")} confirmation=#{memory_action_value(action, :confirmation_id, "none")} count=#{memory_action_count(action)}"
  end

  defp memory_action_path(action) do
    map_value(action, :memory_path) || map_value(action, :archived_path) || "none"
  end

  defp memory_action_count(action) do
    map_value(action, :candidate_count) || map_value(action, :archived_count) ||
      map_value(action, :entry_count) || "none"
  end

  defp memory_action_value(action, key, default), do: map_value(action, key) || default

  defp bounded_inspect(nil), do: "none"

  defp bounded_inspect(value) do
    value
    |> Redactor.redact()
    |> inspect(pretty: true, limit: 20)
  end

  defp intent_resource_access_text(response) do
    access =
      map_value(response, :resource_access) ||
        response
        |> map_value(:decision)
        |> map_value(:resource_access)

    case access do
      entries when is_list(entries) and entries != [] ->
        entries
        |> Redactor.redact()
        |> inspect(pretty: true, limit: :infinity)

      _entries ->
        "none"
    end
  end

  defp workspace_trace(turn) do
    request = Map.get(turn, :request, %{})
    response = Map.get(turn, :response, %{})
    context = workspace_context(turn, response)
    user_id = workspace_value(request, :user_id) || workspace_value(request, :operator_id)
    thread_id = workspace_value(request, :thread_id)

    %{
      user_id: user_id,
      thread_id: thread_id,
      canvas_tiles:
        context_entries(context, [:canvas_tiles, :tiles]) || load_canvas_tiles(thread_id, user_id),
      ephemeral_surfaces:
        context_entries(context, [:ephemeral_surfaces, :ephemerals]) ||
          load_ephemeral_surfaces(thread_id, user_id),
      emitted_fragments:
        context_entries(context, [:recent_emitted_fragments, :emitted_fragments])
        |> recent_entries(),
      dropped_fragments:
        context_entries(context, [:recent_dropped_fragments, :dropped_fragments])
        |> recent_entries()
    }
  end

  defp workspace_context(turn, response) do
    [
      workspace_value(turn, :workspace),
      workspace_value(response, :workspace),
      response
      |> workspace_value(:decision)
      |> workspace_value(:trace_metadata)
      |> workspace_value(:workspace)
    ]
    |> Enum.find(&is_map/1)
    |> case do
      nil -> %{}
      context -> context
    end
  end

  defp load_canvas_tiles(thread_id, user_id) when is_binary(thread_id) and is_binary(user_id) do
    case Workspace.canvas_tiles(thread_id, user_id) do
      {:ok, tiles} -> tiles
      {:error, reason} -> [%{id: "unavailable", kind: "error", body: %{reason: inspect(reason)}}]
    end
  rescue
    exception ->
      [%{id: "unavailable", kind: "error", body: %{reason: Exception.message(exception)}}]
  catch
    :exit, reason ->
      [%{id: "unavailable", kind: "error", body: %{reason: inspect(reason)}}]
  end

  defp load_canvas_tiles(_thread_id, _user_id), do: []

  defp load_ephemeral_surfaces(thread_id, user_id)
       when is_binary(thread_id) and is_binary(user_id) do
    case Workspace.ephemeral_surfaces(thread_id, user_id) do
      {:ok, surfaces} -> surfaces
      {:error, reason} -> [%{id: "unavailable", kind: "error", body: %{reason: inspect(reason)}}]
    end
  rescue
    exception ->
      [%{id: "unavailable", kind: "error", body: %{reason: Exception.message(exception)}}]
  catch
    :exit, reason ->
      [%{id: "unavailable", kind: "error", body: %{reason: inspect(reason)}}]
  end

  defp load_ephemeral_surfaces(_thread_id, _user_id), do: []

  defp context_entries(context, keys) when is_map(context) do
    Enum.find_value(keys, fn key ->
      case workspace_value(context, key) do
        nil -> nil
        entries when is_list(entries) -> entries
        entry -> [entry]
      end
    end)
  end

  defp recent_entries(nil), do: []
  defp recent_entries(entries), do: entries |> List.wrap() |> Enum.take(@workspace_recent_limit)

  defp workspace_inline(workspace) do
    """
    ### Workspace

    - Canvas tiles: #{length(workspace.canvas_tiles)}
    - Ephemeral surfaces: #{length(workspace.ephemeral_surfaces)}
    - Recent emitted fragments: #{length(workspace.emitted_fragments)}
    - Recent dropped fragments: #{length(workspace.dropped_fragments)}
    """
  end

  defp workspace_text(workspace) do
    [
      "- User: #{workspace_line_value(workspace.user_id)}",
      "- Thread: #{workspace_line_value(workspace.thread_id)}",
      "",
      "Canvas tiles:",
      workspace_lines(workspace.canvas_tiles, &workspace_tile_line/1),
      "",
      "Ephemeral surfaces:",
      workspace_lines(workspace.ephemeral_surfaces, &workspace_ephemeral_line/1),
      "",
      "Recent emitted fragments:",
      workspace_lines(workspace.emitted_fragments, &workspace_fragment_line/1),
      "",
      "Recent dropped fragments:",
      workspace_lines(workspace.dropped_fragments, &workspace_fragment_line/1)
    ]
    |> Enum.join("\n")
  end

  defp workspace_lines([], _formatter), do: "none"

  defp workspace_lines(entries, formatter) do
    entries
    |> Enum.map(formatter)
    |> Enum.join("\n")
  end

  defp workspace_tile_line(tile) do
    width = workspace_value(tile, :size_width) || "?"
    height = workspace_value(tile, :size_height) || "?"

    "- #{workspace_line_value(workspace_value(tile, :id))} kind=#{workspace_line_value(workspace_value(tile, :kind))} position=#{workspace_line_value(workspace_value(tile, :position))} pinned=#{workspace_line_value(workspace_value(tile, :pinned))} size=#{width}x#{height} body=#{workspace_body_preview(workspace_value(tile, :body))}"
  end

  defp workspace_ephemeral_line(surface) do
    "- #{workspace_line_value(workspace_value(surface, :id))} kind=#{workspace_line_value(workspace_value(surface, :kind))} pinned=#{workspace_line_value(workspace_value(surface, :pinned))} opened_at=#{workspace_line_value(workspace_value(surface, :opened_at))} body=#{workspace_body_preview(workspace_value(surface, :body))}"
  end

  defp workspace_fragment_line(%{type: type, data: data} = signal) when is_binary(type) do
    "- #{workspace_line_value(workspace_value(data, :fragment_id) || workspace_value(signal, :id))} type=#{type} kind=#{workspace_line_value(workspace_value(data, :kind))} component=#{workspace_line_value(workspace_value(data, :component))} emitter=#{workspace_line_value(workspace_value(data, :emitter_id))} reason=#{workspace_line_value(workspace_value(data, :reason))}"
  end

  defp workspace_fragment_line(fragment) do
    "- #{workspace_line_value(workspace_value(fragment, :fragment_id) || workspace_value(fragment, :id))} kind=#{workspace_line_value(workspace_value(fragment, :kind))} component=#{workspace_line_value(fragment_component(fragment))} emitter=#{workspace_line_value(workspace_value(fragment, :emitter_id))} reason=#{workspace_line_value(workspace_value(fragment, :reason))} emitted_at=#{workspace_line_value(workspace_value(fragment, :emitted_at))}"
  end

  defp fragment_component(fragment) do
    workspace_value(fragment, :component) ||
      fragment
      |> workspace_value(:surface)
      |> surface_component()
  end

  defp surface_component(%{nodes: [node | _rest]}), do: workspace_value(node, :component)
  defp surface_component(_surface), do: nil

  defp workspace_body_preview(nil), do: "empty"
  defp workspace_body_preview(body) when body == %{}, do: "empty"

  defp workspace_body_preview(body) do
    body
    |> Redactor.redact()
    |> inspect(pretty: false, limit: 20)
    |> bounded_trace_value(200)
  end

  defp workspace_line_value(nil), do: "none"
  defp workspace_line_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp workspace_line_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp workspace_line_value(value) when is_binary(value), do: value
  defp workspace_line_value(value) when is_atom(value), do: Atom.to_string(value)
  defp workspace_line_value(value), do: inspect(value)

  defp workspace_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp workspace_value(_map, _key), do: nil

  defp bounded_trace_value(value, max_bytes) when byte_size(value) > max_bytes do
    binary_part(value, 0, max_bytes) <> "..."
  end

  defp bounded_trace_value(value, _max_bytes), do: value

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
