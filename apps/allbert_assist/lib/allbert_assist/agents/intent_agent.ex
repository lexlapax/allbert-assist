defmodule AllbertAssist.Agents.IntentAgent do
  @moduledoc """
  Primary v0.01 Allbert intent agent.

  The module is a lightweight `Jido.Agent`-compatible deterministic router.
  It exposes `respond/1` for the v0.01 runtime path and keeps the first
  operator loop fast, testable, and conservative while the supervised Jido
  agent substrate is in place for later milestones.
  """

  @behaviour Jido.Agent

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.ConversationContext
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.Intent.PendingClarification
  alias AllbertAssist.Intent.ResourceAccess
  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.ClarifyResolver
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.PendingStore
  alias AllbertAssist.Intent.Slots
  alias AllbertAssist.Objectives.Engine.Agent, as: ObjectivesEngine
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Runtime.SafeTerm
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.ActionPlan
  alias AllbertAssist.Workflows
  alias AllbertAssist.Workspace.Emitters, as: WorkspaceEmitters
  alias Jido.Agent, as: JidoAgent
  alias Jido.Agent.State, as: JidoAgentState
  alias Jido.Error, as: JidoError
  alias Jido.Util, as: JidoUtil

  @agent_name "intent_agent"
  @agent_description "Primary Allbert intent agent for the first local assistant loop."
  @agent_tags []
  @marketplace_entry_id_regex ~r/[a-z0-9][a-z0-9_-]*\/[a-z0-9][a-z0-9_-]*/i
  @agent_schema Zoi.object(%{
                  __strategy__: Zoi.map() |> Zoi.default(%{}),
                  model: Zoi.any() |> Zoi.default(:local),
                  requests: Zoi.map() |> Zoi.default(%{}),
                  last_request_id: Zoi.string() |> Zoi.optional(),
                  last_query: Zoi.string() |> Zoi.default(""),
                  last_answer: Zoi.string() |> Zoi.default(""),
                  completed: Zoi.boolean() |> Zoi.default(false)
                })

  @doc "Return the agent name used by app and Jido metadata surfaces."
  def name, do: @agent_name

  @doc "Return the agent description used by app and Jido metadata surfaces."
  def description, do: @agent_description

  @doc "IntentAgent is not categorized in the generic Jido catalog."
  def category, do: nil

  @doc "Return metadata tags for this agent."
  def tags, do: @agent_tags

  @doc "IntentAgent does not publish an independent version."
  def vsn, do: nil

  @doc "Return the small state schema used when this module is treated as a Jido agent."
  def schema, do: @agent_schema

  @doc "Return Jido metadata for discovery-style callers."
  def __agent_metadata__ do
    %{
      module: __MODULE__,
      name: name(),
      description: description(),
      category: category(),
      tags: tags(),
      vsn: vsn(),
      actions: actions(),
      schema: schema()
    }
  end

  @doc "The deterministic runtime does not expose Jido command actions."
  def actions, do: []

  @impl true
  def signal_routes, do: []

  @impl true
  def signal_routes(_ctx), do: signal_routes()

  @doc "Create a lightweight Jido agent struct for discovery and future AgentServer use."
  def new(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts
    id = normalize_id(Map.get(opts, :id))
    state = Map.merge(default_state(), Map.get(opts, :state, %{}))

    %JidoAgent{
      id: id,
      agent_module: __MODULE__,
      name: name(),
      description: description(),
      category: category(),
      tags: tags(),
      vsn: vsn(),
      schema: schema(),
      state: state
    }
  end

  @doc "Merge state into a Jido agent struct."
  def set(%JidoAgent{} = agent, attrs) do
    {:ok, %{agent | state: Map.merge(agent.state, Map.new(attrs))}}
  end

  @doc "Validate a Jido agent struct against the local state schema."
  def validate(%JidoAgent{} = agent, opts \\ []) do
    case JidoAgentState.validate(agent.state, agent.schema, opts) do
      {:ok, validated_state} ->
        {:ok, %{agent | state: validated_state}}

      {:error, reason} ->
        {:error, JidoError.validation_error("State validation failed", %{reason: reason})}
    end
  end

  @doc "No-op Jido command entrypoint; Allbert runtime uses respond/1 below."
  def cmd(%JidoAgent{} = agent, _action), do: {agent, []}
  def cmd(%JidoAgent{} = agent, _action, opts) when is_list(opts), do: {agent, []}

  @impl true
  def on_before_cmd(%JidoAgent{} = agent, action), do: {:ok, agent, action}

  @impl true
  def on_after_cmd(%JidoAgent{} = agent, _action, directives), do: {:ok, agent, directives}

  @impl true
  def checkpoint(%JidoAgent{} = agent, _ctx), do: {:ok, %{id: agent.id, state: agent.state}}

  @impl true
  def restore(data, _ctx) when is_map(data) do
    {:ok, new(id: data[:id] || data["id"], state: data[:state] || data["state"] || %{})}
  end

  defp normalize_id(nil), do: JidoUtil.generate_id()
  defp normalize_id(""), do: JidoUtil.generate_id()
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id), do: to_string(id)

  defp default_state do
    %{
      __strategy__: %{},
      model: :local,
      requests: %{},
      last_query: "",
      last_answer: "",
      completed: false
    }
  end

  @doc """
  Respond to one normalized runtime request.

  v0.01 currently uses deterministic routing over the same named action
  surface registered in Allbert's action registry. Later milestones can move
  more of this selection into the supervised agent loop after permissions,
  memory, and traces are stronger.
  """
  @spec respond(map()) :: {:ok, map()} | {:error, term()}
  def respond(%{text: text} = request) when is_binary(text) do
    text = String.trim(text)
    context = %{request: request, agent: __MODULE__}

    route =
      if coding_turn?(context) do
        :direct_answer
      else
        text |> route(context) |> execution_route(text)
      end

    case decision_for_route(route, text, context) do
      {:ok, decision} ->
        engine_result =
          request
          |> engine_request(route, decision)
          |> Engine.decide()

        handle_engine_decision(engine_result, route, text, context, decision)

      {:error, reason} ->
        {:ok, invalid_decision_response(reason, text, context)}
    end
  end

  def respond(_request), do: {:error, :missing_text}

  defp engine_request(request, route, %Decision{} = decision) do
    force_direct_answer? = route == :direct_answer and job_channel?(%{request: request})
    request = Map.put(request, :route_hint, route_hint(route, force_direct_answer?))

    if route == :direct_answer and not force_direct_answer? do
      request
    else
      Map.put(request, :route_decision, decision)
    end
  end

  defp route_hint(route, force_direct_answer?) do
    %{
      route: route_name(route),
      explicit?: route != :direct_answer or force_direct_answer?,
      source: route_hint_source(force_direct_answer?)
    }
  end

  defp route_hint_source(true), do: :job_runtime_prompt_guard
  defp route_hint_source(false), do: :intent_agent_predicates

  defp route_name(route) when is_atom(route), do: route
  defp route_name({route, _value}), do: route
  defp route_name({route, _value1, _value2}), do: route

  defp mcp_route?({route, _params})
       when route in [:mcp_list_tools, :mcp_list_resources, :mcp_read_resource, :mcp_call_tool],
       do: true

  defp mcp_route?(_route), do: false

  defp handle_engine_decision(engine_result, route, text, context, %Decision{} = route_decision) do
    if coding_turn?(context) do
      run_deterministic_route(:direct_answer, text, context, route_decision)
    else
      handle_non_coding_engine_decision(engine_result, route, text, context, route_decision)
    end
  end

  defp handle_non_coding_engine_decision(
         {:ok, %Decision{intent: :open_surface} = decision},
         _route,
         _text,
         _context,
         _route_decision
       ),
       do: {:ok, surface_navigation_response(decision)}

  defp handle_non_coding_engine_decision(
         {:ok, %Decision{} = engine_decision},
         route,
         text,
         context,
         route_decision
       ) do
    decision = if mcp_route?(route), do: route_decision, else: engine_decision
    run_validated_route(route, text, context, decision)
  end

  defp handle_non_coding_engine_decision(
         {:error, _reason},
         route,
         text,
         context,
         route_decision
       ),
       do: run_validated_route(route, text, context, route_decision)

  defp run_validated_route(route, text, context, %Decision{} = decision) do
    # v0.54 (ADR 0060): first resolve any pending clarification this reply answers;
    # otherwise route via the two-stage intent router (which defers to the
    # deterministic ladder under `:deterministic` or on model/index unavailability).
    case resolve_pending_clarification(text, context, decision) do
      {:resolved, result} -> result
      :none -> route_with_router(route, text, context, decision)
    end
  end

  defp route_with_router(route, text, context, %Decision{} = decision) do
    if coding_turn?(context) do
      run_deterministic_route(:direct_answer, text, context, decision)
    else
      route_with_router_outcome(route, text, context, decision)
    end
  end

  defp route_with_router_outcome(route, text, context, %Decision{} = decision) do
    # v1.0 M7.1/M7.3: the two-stage router exists to catch what the deterministic
    # ladder cannot match. Every ladder route is an exact typed contract (command
    # phrases, capability questions, memory/settings requests); the router must
    # never override one — it engages only when the ladder found nothing
    # (:direct_answer).
    if route == :direct_answer do
      route_with_router_outcome_via_router(route, text, context, decision)
    else
      run_deterministic_route(route, text, context, decision)
    end
  end

  defp route_with_router_outcome_via_router(route, text, context, %Decision{} = decision) do
    case router_outcome(text, context) do
      {:ok, %Outcome{kind: :execute, action_name: action_name, slots: slots}}
      when is_binary(action_name) ->
        run_router_action(action_name, slots, text, context, decision)

      {:ok, %Outcome{kind: :clarify} = outcome} ->
        {:ok, router_clarify_response(outcome, context, decision)}

      {:ok, %Outcome{kind: :answer}} ->
        run_deterministic_route(:direct_answer, text, context, decision)

      {:ok, %Outcome{kind: :none}} ->
        {:ok, router_none_response(decision)}

      _defer ->
        run_deterministic_route(route, text, context, decision)
    end
  end

  defp coding_turn?(%{request: request}) when is_map(request) do
    metadata = field(request, :metadata, %{}) || %{}

    truthy?(field(request, :coding_turn?)) ||
      truthy?(field(request, :coding_turn)) ||
      truthy?(field(metadata, :coding_turn?)) ||
      truthy?(field(metadata, :coding_turn)) ||
      field(metadata, :surface) in ["pi_mode", "coding", "tui_pi_mode"]
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end

  defp field(_map, _key, default), do: default

  defp run_deterministic_route(route, text, context, %Decision{} = decision) do
    cond do
      Decision.refused?(decision) ->
        {:ok, decision_refusal_response(decision)}

      intent_handoff_decision?(decision) ->
        {:ok, intent_handoff_response(decision, context)}

      objective_framing_candidate?(decision) ->
        text
        |> run_objective_route(context, decision)
        |> attach_decision(decision, context)

      true ->
        execution_context = Map.put(context, :decision, decision)

        route
        |> execution_route_for_decision(decision)
        |> run_route(text, execution_context)
        |> attach_decision(decision, context)
    end
  end

  # ── v0.54 intent router integration (ADR 0060) ───────────────────────────────

  defp router_outcome(text, context) do
    request = context |> Map.get(:request, %{}) |> Map.put(:text, text)

    conversation =
      ConversationContext.from_thread_context(
        Map.get(request, :thread_context, %{}) || %{},
        prior_app: Map.get(request, :active_app)
      )

    router_context = %{
      summary: conversation.summary,
      prior_app: conversation.prior_app,
      prior_action: conversation.prior_action
    }

    Router.route(request, [], router_context)
  rescue
    _exception -> {:ok, Outcome.defer(:router_error)}
  catch
    :exit, _reason -> {:ok, Outcome.defer(:router_exit)}
  end

  defp run_router_action(action_name, slots, text, context, %Decision{} = decision) do
    execution_context =
      context
      |> put_router_active_app(action_name)
      |> Map.put(:decision, decision)

    params =
      action_name |> registry_action_params(text, execution_context) |> merge_router_slots(slots)

    case missing_required_action_params(action_name, params) do
      [] ->
        action_name
        |> run_action(params, text, execution_context)
        |> attach_decision(decision, context)

      missing ->
        {:ok, router_missing_params_response(action_name, missing, context, decision)}
    end
  end

  # v0.54 (ADR 0034/0060): a router-selected app-scoped action runs **in its own
  # app**. Set the execution-context active app to the action's `app_id` so the
  # runner's app-scope gate permits it — this is the direct-execute equivalent of
  # the former app handoff (which switched the active app before running). Routing
  # grants no authority: the action's own permission/confirmation gate is unchanged,
  # and only the registry-validated selected action's app is set (for this run only).
  defp put_router_active_app(context, action_name) do
    case Registry.capability(action_name) do
      {:ok, %{app_id: app_id}} when not is_nil(app_id) ->
        Map.put(context, :active_app, app_id)

      _other ->
        context
    end
  end

  # Router slots are (possibly degraded) model output. `Intent.Slots` is the
  # single canonical seam that coerces them to a map, drops keys that do not
  # resolve to an existing atom, and never overwrites a param already set.
  defp merge_router_slots(params, slots), do: Slots.merge(params, slots, key_mode: :existing_atom)

  defp router_clarify_response(
         %Outcome{shortlist: shortlist, question: question},
         context,
         %Decision{} = decision
       ) do
    options = clarify_options(shortlist)
    persist_clarification(context, question, options)
    clarification_response(decision, question, options)
  end

  defp clarify_options(shortlist) do
    shortlist
    |> SafeTerm.wrap_list()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      %{
        kind: :action,
        id: to_string(Map.get(item, :action_name) || Map.get(item, :id) || ""),
        label: Map.get(item, :label)
      }
    end)
    |> Enum.reject(&(&1.id == ""))
  end

  defp router_missing_params_response(action_name, missing, context, %Decision{} = decision) do
    label = action_label(action_name)
    missing_names = format_param_names(missing)

    question =
      "I can run #{label}, but I need #{missing_names} first. Please provide the missing details."

    options = [
      %{
        kind: :action,
        id: action_name,
        label: label,
        missing_params: Enum.map(missing, &Atom.to_string/1)
      }
    ]

    persist_clarification(context, question, options)
    clarification_response(decision, question, options)
  end

  defp action_label(action_name), do: action_name |> to_string() |> String.replace("_", " ")

  defp persist_clarification(context, question, options) do
    request = Map.get(context, :request, %{})
    now = DateTime.utc_now()

    PendingStore.put(%PendingClarification{
      thread_id: Map.get(request, :thread_id),
      user_id: Map.get(request, :user_id),
      session_id: Map.get(request, :session_id),
      question: question,
      options: options,
      created_at: now,
      expires_at: DateTime.add(now, clarification_ttl_ms(), :millisecond)
    })

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp clarification_response(%Decision{} = decision, question, options) do
    %{
      message: question,
      status: :needs_clarification,
      decision: decision,
      resource_access: [],
      approval_handoff: nil,
      diagnostics: decision.diagnostics,
      intent_clarification: %{question: question, options: options},
      actions: [
        %{name: "clarify_intent", status: :awaiting_clarification, permission: :read_only}
      ]
    }
  end

  defp router_none_response(%Decision{} = decision) do
    %{
      message:
        "I couldn't match that to anything I can do. Could you rephrase or ask for something else?",
      status: :completed,
      decision: decision,
      resource_access: [],
      approval_handoff: nil,
      diagnostics: decision.diagnostics,
      actions: []
    }
  end

  defp resolve_pending_clarification(text, context, %Decision{} = decision) do
    request = Map.get(context, :request, %{})

    case take_pending(Map.get(request, :user_id), Map.get(request, :thread_id)) do
      {:ok, %PendingClarification{options: options}} ->
        case ClarifyResolver.resolve(text, options) do
          {:ok, %{id: action_name}} when is_binary(action_name) and action_name != "" ->
            {:resolved, run_router_action(action_name, %{}, text, context, decision)}

          _no_match ->
            :none
        end

      :none ->
        :none
    end
  end

  defp take_pending(user_id, thread_id) do
    PendingStore.take(user_id, thread_id)
  rescue
    _exception -> :none
  catch
    :exit, _reason -> :none
  end

  defp clarification_ttl_ms do
    case Settings.get("intent.pending_clarification_ttl_ms") do
      {:ok, value} when is_integer(value) -> value
      _other -> 120_000
    end
  end

  defp handoff_clarify_options(%Decision{selected_action: action})
       when is_binary(action) and action != "" do
    [%{kind: :action, id: action, label: action}]
  end

  defp handoff_clarify_options(_decision), do: []

  defp execution_route_for_decision(
         :direct_answer,
         %Decision{
           intent: :registry_action,
           selected_action: action_name
         }
       )
       when is_binary(action_name) do
    {:registry_action, action_name}
  end

  defp execution_route_for_decision(route, _decision), do: route

  defp surface_navigation_response(%Decision{} = decision) do
    target = Map.get(decision.trace_metadata, :surface_target, %{})
    label = Map.get(target, :label) || "registered surface"
    path = Map.get(target, :path)

    %{
      message: surface_navigation_message(label, path),
      status: :completed,
      active_app: decision.active_app,
      decision: decision,
      resource_access: [],
      approval_handoff: nil,
      diagnostics: decision.diagnostics,
      actions: []
    }
  end

  defp surface_navigation_message(label, path) when is_binary(path) do
    "Open #{label}: #{path}"
  end

  defp surface_navigation_message(label, _path), do: "Open #{label}."

  @doc "Return the action modules that define the v0.01 intent surface."
  def action_modules do
    Registry.agent_modules()
  end

  defp route(text, context) do
    normalized = String.downcase(text)

    [
      fn -> settings_route(text, normalized) end,
      fn -> skill_import_route(text, normalized) end,
      fn -> skill_script_route(text, normalized) end,
      fn -> package_route(text, normalized) end,
      fn -> online_skill_route(text, normalized) end,
      fn -> uri_consumer_route(text, normalized) end,
      fn -> mcp_route(text, normalized) end,
      fn -> plan_build_route(text, normalized) end,
      fn -> marketplace_route(text, normalized) end,
      fn -> self_improvement_route(text, normalized) end,
      fn -> tool_discovery_route(text, normalized) end,
      fn -> unsupported_resource_workflow_route(text, normalized) end,
      fn -> command_route(normalized, context) end,
      fn -> channel_send_route(text, normalized) end,
      fn -> external_network_route(normalized) end,
      fn -> explicit_memory_route(normalized) end,
      fn -> personal_memory_route(text) end,
      fn -> memory_read_route(text, normalized) end,
      fn -> skill_route(text, normalized) end,
      fn -> capability_route(normalized) end
    ]
    |> Enum.find_value(:direct_answer, & &1.())
  end

  defp command_route(text, context),
    do: if(command_request?(text, context), do: :run_shell_command)

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

  # v1.0.1 M4.3 (DIT-4(b), M7.1/R8 precedent): natural channel-send phrasing gets
  # a deterministic ladder route so the two-stage router can never misroute it to
  # `external_network_request` (whose empty `required_slots` made it the only
  # executable candidate and produced a `:missing_url` denial). Authority is
  # unchanged: `send_channel_message` still runs the identity-allowlist target
  # gate and the confirmation-gated outbound Gate.
  defp channel_send_route(text, _normalized) do
    case Regex.named_captures(
           ~r/^\s*send\s+(?:the\s+)?(?:exact\s+)?message\s+(?<body>.+?)\s+(?:to|on|via)\s+my\s+(?:configured\s+)?(?<channel>[a-z][a-z0-9_-]*)\s+channel\W*$/i,
           text
         ) do
      %{"body" => body, "channel" => channel} ->
        channel = String.downcase(channel)

        {:send_channel_message,
         %{channel: channel, body: body, target: configured_channel_target(channel)}}

      nil ->
        nil
    end
  end

  # "My configured <channel> channel" resolves to the channel's single ENABLED
  # identity-mapped recipient; anything else (zero or several) stays unresolved
  # ("") so the action reports honestly instead of the ladder guessing a target.
  defp configured_channel_target(channel) do
    with {:ok, settings} <- AllbertAssist.Channels.channel_settings(channel),
         identity_map when is_list(identity_map) <- Map.get(settings, "identity_map", []) do
      identity_map
      |> Enum.filter(fn entry -> Map.get(entry, "enabled", true) != false end)
      |> case do
        [entry] -> to_string(Map.get(entry, "external_user_id", ""))
        _zero_or_many -> ""
      end
    else
      _other -> ""
    end
  end

  defp plan_build_route(text, normalized) do
    preview_plan_route(text) ||
      run_workflow_route(text) ||
      run_existing_workflow_route(text) ||
      cancel_plan_route(text) ||
      show_plan_route(text) ||
      list_workflows_route(normalized) ||
      list_plan_runs_route(normalized)
  end

  defp preview_plan_route(text) do
    if Regex.match?(~r/^\s*plan\s*:?\s+\S/i, text) do
      {:preview_plan, %{plan_text: String.replace(text, ~r/^\s*plan\s*:?\s*/i, "")}}
    end
  end

  defp run_workflow_route(text) do
    if Regex.match?(~r/^\s*run\s+workflow\s+#{workflow_id_pattern()}\s*$/i, text) do
      {:start_plan_run, %{workflow_id: workflow_id_from_suffix(text)}}
    end
  end

  defp run_existing_workflow_route(text) do
    if Regex.match?(~r/^\s*run\s+#{workflow_id_pattern()}\s*$/i, text) do
      workflow_id = workflow_id_from_suffix(text)
      if Workflows.exists?(workflow_id), do: {:start_plan_run, %{workflow_id: workflow_id}}
    end
  end

  defp cancel_plan_route(text) do
    if Regex.match?(~r/^\s*cancel\s+plan\s+#{objective_id_pattern()}\s*$/i, text) do
      {:cancel_plan_run, %{objective_id: objective_id_from_suffix(text)}}
    end
  end

  defp show_plan_route(text) do
    if Regex.match?(~r/^\s*show\s+plan\s+#{objective_id_pattern()}\s*$/i, text) do
      {:show_plan, %{id: objective_id_from_suffix(text)}}
    end
  end

  defp list_workflows_route(normalized) do
    if normalized in ["list workflows", "show workflows"], do: :list_workflows
  end

  defp list_plan_runs_route(normalized) do
    if normalized in ["list plans", "show plans"], do: :list_plan_runs
  end

  defp tool_discovery_route(text, normalized) do
    if tool_discovery_request?(normalized), do: {:find_tools, tool_discovery_query(text)}
  end

  defp self_improvement_route(text, normalized) do
    if self_improvement_enabled?() do
      cond do
        normalized == "show self-improvement suggestions" ->
          {:discover_patterns, %{query: text}}

        String.contains?(normalized, "what could you turn into a skill") ->
          {:discover_patterns, %{query: text}}

        String.contains?(normalized, "what could you turn into a workflow") ->
          {:discover_patterns, %{query: text}}

        true ->
          nil
      end
    end
  end

  defp marketplace_route(text, normalized) do
    reviewed_skill_catalog_route(normalized) ||
      reviewed_templates_route(normalized) ||
      installed_marketplace_route(normalized) ||
      browse_marketplace_route(text, normalized) ||
      install_marketplace_route(text) ||
      rollback_marketplace_route(text) ||
      verify_marketplace_route(text)
  end

  defp reviewed_skill_catalog_route(normalized) do
    if normalized in ["show me the reviewed skill catalog", "show me reviewed skill catalog"] do
      {:list_marketplace_entries, %{kind: "skill"}}
    end
  end

  defp reviewed_templates_route(normalized) do
    if normalized == "show me reviewed templates" do
      {:list_marketplace_entries, %{kind: "template"}}
    end
  end

  defp installed_marketplace_route(normalized) do
    if String.contains?(normalized, "installed marketplace") do
      :list_installed_marketplace_bundles
    end
  end

  defp browse_marketplace_route(text, normalized) do
    if String.contains?(normalized, "marketplace") and
         Regex.match?(~r/\b(what|show|list|catalog)\b/i, text) do
      {:list_marketplace_entries, %{}}
    end
  end

  defp install_marketplace_route(text) do
    if Regex.match?(~r/^\s*install\s+the\s+#{marketplace_entry_id_pattern()}\s+skill\s*$/i, text) do
      {:install_marketplace_bundle, %{entry_id: marketplace_entry_id_from_text(text)}}
    end
  end

  defp rollback_marketplace_route(text) do
    if Regex.match?(~r/^\s*rollback\s+#{marketplace_entry_id_pattern()}\s*$/i, text) do
      {:rollback_marketplace_install, %{entry_id: marketplace_entry_id_from_text(text)}}
    end
  end

  defp verify_marketplace_route(text) do
    if Regex.match?(~r/^\s*verify\s+#{marketplace_entry_id_pattern()}\s*$/i, text) do
      {:verify_marketplace_bundle_hash, %{entry_id: marketplace_entry_id_from_text(text)}}
    end
  end

  defp workflow_id_pattern, do: "[a-z0-9][a-z0-9_-]*"

  defp marketplace_entry_id_pattern, do: "[a-z0-9][a-z0-9_-]*\\/[a-z0-9][a-z0-9_-]*"

  defp marketplace_entry_id_from_text(text) do
    text
    |> then(&Regex.scan(@marketplace_entry_id_regex, &1))
    |> List.last()
    |> case do
      [entry_id] -> String.downcase(entry_id)
      _other -> nil
    end
  end

  defp objective_id_pattern,
    do: "obj_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

  defp workflow_id_from_suffix(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> List.last()
    |> String.downcase()
  end

  defp objective_id_from_suffix(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> List.last()
  end

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
    cond do
      Regex.match?(~r/^\s*set\s+my\s+communication\s+style\s+to\s+.+/i, text) ->
        {:update_setting, "operator.communication_style", value_after_to(text)}

      provider_secret_setting_write?(text) ->
        {:set_provider_credential, provider_from_secret_setting_write(text), :raw_prompt_secret}

      match = generic_setting_write(text) ->
        match

      true ->
        nil
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

  defp generic_setting_write(text) do
    case Regex.named_captures(
           ~r/^\s*(?:set|change)\s+(?:setting\s+)?(?<key>[a-z0-9_]+(?:\.[a-z0-9_]+)+)\s*(?:to|=)\s*(?<value>.+?)\s*$/i,
           text
         ) do
      %{"key" => key, "value" => value} ->
        key = String.downcase(key)

        if setting_route_key?(key) and not sensitive_setting_key?(key) do
          {:update_setting, key, normalize_setting_value(value)}
        end

      _other ->
        nil
    end
  end

  defp provider_secret_setting_write?(text) do
    case generic_setting_write_parts(text) do
      {key, _value} -> sensitive_setting_key?(key)
      nil -> false
    end
  end

  defp provider_from_secret_setting_write(text) do
    case generic_setting_write_parts(text) do
      {key, _value} ->
        case Regex.run(~r/^providers\.([a-z0-9_-]+)\./, key) do
          [_match, provider] -> provider
          _other -> "provider"
        end

      nil ->
        "provider"
    end
  end

  defp generic_setting_write_parts(text) do
    case Regex.named_captures(
           ~r/^\s*(?:set|change)\s+(?:setting\s+)?(?<key>[a-z0-9_]+(?:\.[a-z0-9_]+)+)\s*(?:to|=)\s*(?<value>.+?)\s*$/i,
           text
         ) do
      %{"key" => key, "value" => value} ->
        {String.downcase(key), normalize_setting_value(value)}

      _other ->
        nil
    end
  end

  defp setting_route_key?(key) do
    Settings.safe_write_key?(key) or Settings.known_key?(key)
  rescue
    _exception -> false
  end

  defp sensitive_setting_key?(key) do
    Regex.match?(~r/(api[_-]?key|secret|credential|password|token)/i, key)
  end

  defp normalize_setting_value(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp execution_route(:run_shell_command, text) do
    case command_params_from_text(text) do
      {:ok, _params} -> :run_shell_command
      {:error, _reason} -> :plan_shell_command
    end
  end

  defp execution_route(route, _text), do: route

  defp decision_for_route(route, text, context) do
    route
    |> decision_attrs(text, context)
    |> Decision.new()
  end

  defp decision_attrs(:plan_shell_command, text, context) do
    %{
      intent: :plan_shell_command,
      reason: "The prompt asks for shell command planning without execution.",
      selected_skill: "plan-shell-command",
      selected_action: "plan_shell_command",
      resource_access: command_resource_access(text, "plan_shell_command", :prospective),
      alternatives: ["Review the planned command before asking Allbert to run it."],
      context: context
    }
  end

  defp decision_attrs(:run_shell_command, text, context) do
    %{
      intent: :run_shell_command,
      reason: "The prompt asks to run a local shell command.",
      selected_action: "run_shell_command",
      resource_access: command_resource_access(text, "run_shell_command", :execution),
      alternatives: ["Ask for a command plan instead of execution."],
      context: context
    }
  end

  defp decision_attrs(:external_network_request, text, context) do
    %{
      intent: :external_network_request,
      reason: "The prompt asks for an external HTTP or service request.",
      selected_skill: "external-network-request",
      selected_action: "external_network_request",
      resource_access:
        url_resource_access(text, :external_service_request, "external_network_request"),
      alternatives: ["Ask for a plan or provide local content instead of fetching."],
      context: context
    }
  end

  defp decision_attrs({:url_summary, url}, text, context) do
    %{
      intent: :summarize_url,
      reason:
        "The prompt asks to fetch a URL through the confirmed network substrate before summarization.",
      selected_skill: "external-network-request",
      selected_action: "external_network_request",
      resource_access: url_resource_access(url, :summarize_url, "external_network_request"),
      alternatives: ["Provide the page text directly or approve a bounded URL fetch first."],
      trace_metadata: %{source_text: text, url: url, postprocess: :summarize_url},
      context: context
    }
  end

  defp decision_attrs({:document_url_inspection, url}, text, context) do
    %{
      intent: :inspect_document,
      reason:
        "The prompt asks to fetch a remote document URL through the confirmed network substrate before extraction.",
      selected_skill: "external-network-request",
      selected_action: "external_network_request",
      resource_access: url_resource_access(url, :inspect_document, "external_network_request"),
      alternatives: [
        "Provide already-extracted document text or approve a bounded document URL fetch."
      ],
      trace_metadata: %{source_text: text, url: url, postprocess: :inspect_document},
      context: context
    }
  end

  defp decision_attrs({:unsupported_resource_workflow, workflow, resource}, text, context) do
    %{
      intent: workflow,
      reason:
        "The prompt asks for a URI resource workflow that is represented but not executable by this route.",
      selected_skill: "unsupported-resource-workflow",
      selected_action: "unsupported_resource_workflow",
      confirmation: :unsupported,
      resource_access: workflow_resource_access(workflow, resource || resource_hint(text), text),
      alternatives: unsupported_alternatives(workflow),
      context: context
    }
  end

  defp decision_attrs({:mcp_list_tools, params}, text, context) do
    mcp_decision_attrs(
      :mcp_list_tools,
      "mcp_list_tools",
      "The prompt asks to list tools from a configured MCP server.",
      params,
      [],
      text,
      context
    )
  end

  defp decision_attrs({:mcp_list_resources, params}, text, context) do
    mcp_decision_attrs(
      :mcp_list_resources,
      "mcp_list_resources",
      "The prompt asks to list resources from a configured MCP server.",
      params,
      [],
      text,
      context
    )
  end

  defp decision_attrs({:mcp_read_resource, params}, text, context) do
    mcp_decision_attrs(
      :mcp_read_resource,
      "mcp_read_resource",
      "The prompt asks to read an MCP resource through Resource Access.",
      params,
      mcp_resource_access(params, "mcp_read_resource"),
      text,
      context
    )
  end

  defp decision_attrs({:mcp_call_tool, params}, text, context) do
    mcp_decision_attrs(
      :mcp_call_tool,
      "mcp_call_tool",
      "The prompt asks to call an MCP tool through a confirmed action.",
      params,
      mcp_tool_resource_access(params, "mcp_call_tool"),
      text,
      context
    )
  end

  defp decision_attrs({:local_file_inspection, path}, text, context) do
    %{
      intent: :read_local_path,
      reason:
        "The prompt asks to inspect a generic local file, but v0.11 has no registered bounded reader.",
      selected_skill: "unsupported-resource-workflow",
      selected_action: "unsupported_resource_workflow",
      confirmation: :unsupported,
      resource_access: local_file_resource_access(path, "unsupported_resource_workflow"),
      alternatives: [
        "Paste the relevant text directly.",
        "Add a later bounded local read action with confirmation and caps."
      ],
      trace_metadata: %{source_text: text, local_path: path},
      context: context
    }
  end

  defp decision_attrs(:append_memory, text, context) do
    skill_decision_attrs(:append_memory, "append-memory", "append_memory", text, context)
  end

  defp decision_attrs({:append_personal_memory, _memory}, text, context) do
    skill_decision_attrs(:append_personal_memory, "append-memory", "append_memory", text, context)
  end

  defp decision_attrs({:read_recent_memory, _query}, text, context) do
    skill_decision_attrs(
      :read_recent_memory,
      "read-recent-memory",
      "read_recent_memory",
      text,
      context
    )
  end

  defp decision_attrs({:read_skill, _name}, text, context) do
    skill_decision_attrs(:read_skill, "read-skill", "read_skill", text, context)
  end

  defp decision_attrs({:activate_skill, name}, _text, context) do
    %{
      intent: :activate_skill,
      reason:
        "The prompt asks to activate trusted skill instructions for progressive disclosure.",
      selected_skill: name,
      selected_action: "activate_skill",
      alternatives: ["List available skills before activating one."],
      context: context
    }
  end

  defp decision_attrs(:list_skills, text, context) do
    skill_decision_attrs(:list_skills, "list-skills", "list_skills", text, context)
  end

  defp decision_attrs({:find_tools, _query}, text, context) do
    %{
      intent: :find_tools,
      reason: "The prompt asks to find matching tool candidates.",
      selected_action: "find_tools",
      trace_metadata: %{source_text: text},
      context: context
    }
  end

  defp decision_attrs({:discover_patterns, params}, text, context) do
    %{
      intent: :discover_patterns,
      reason: "The prompt asks for self-improvement pattern suggestions.",
      selected_action: "discover_patterns",
      trace_metadata: %{source_text: text, discovery_params: params},
      context: context
    }
  end

  defp decision_attrs({:preview_plan, params}, text, context) do
    %{
      intent: :plan_preview,
      reason: "The prompt explicitly asks for a Plan/Build preview.",
      selected_action: "preview_plan",
      trace_metadata: %{source_text: text, plan_params: params},
      context: context
    }
  end

  defp decision_attrs({:send_channel_message, params}, text, context) do
    %{
      intent: :channel_message_send,
      reason: "The prompt explicitly asks to send a message to a configured channel.",
      selected_action: "send_channel_message",
      trace_metadata: %{source_text: text, channel: params[:channel]},
      context: context
    }
  end

  defp decision_attrs({:start_plan_run, params}, text, context) do
    %{
      intent: :plan_run_start,
      reason: "The prompt explicitly asks to run an operator workflow.",
      selected_action: "start_plan_run",
      trace_metadata: %{source_text: text, plan_params: params},
      context: context
    }
  end

  defp decision_attrs({:cancel_plan_run, params}, text, context) do
    %{
      intent: :plan_cancel,
      reason: "The prompt explicitly asks to cancel a plan run.",
      selected_action: "cancel_plan_run",
      trace_metadata: %{source_text: text, plan_params: params},
      context: context
    }
  end

  defp decision_attrs({:show_plan, params}, text, context) do
    %{
      intent: :show_plan,
      reason: "The prompt explicitly asks to show a plan run.",
      selected_action: "show_objective",
      trace_metadata: %{source_text: text, plan_params: params},
      context: context
    }
  end

  defp decision_attrs(:list_workflows, text, context) do
    %{
      intent: :list_workflows,
      reason: "The prompt explicitly asks to list operator workflows.",
      selected_action: "list_workflows",
      trace_metadata: %{source_text: text},
      context: context
    }
  end

  defp decision_attrs(:list_plan_runs, text, context) do
    %{
      intent: :list_plan_runs,
      reason: "The prompt explicitly asks to list plan runs.",
      selected_action: "list_plan_runs",
      trace_metadata: %{source_text: text},
      context: context
    }
  end

  defp decision_attrs({:list_marketplace_entries, params}, text, context) do
    marketplace_decision_attrs(
      :marketplace_browse,
      "list_marketplace_entries",
      params,
      text,
      context
    )
  end

  defp decision_attrs(:list_installed_marketplace_bundles, text, context) do
    marketplace_decision_attrs(
      :marketplace_installed,
      "list_installed_marketplace_bundles",
      %{},
      text,
      context
    )
  end

  defp decision_attrs({:install_marketplace_bundle, params}, text, context) do
    marketplace_decision_attrs(
      :marketplace_install,
      "install_marketplace_bundle",
      params,
      text,
      context
    )
  end

  defp decision_attrs({:rollback_marketplace_install, params}, text, context) do
    marketplace_decision_attrs(
      :marketplace_rollback,
      "rollback_marketplace_install",
      params,
      text,
      context
    )
  end

  defp decision_attrs({:verify_marketplace_bundle_hash, params}, text, context) do
    marketplace_decision_attrs(
      :marketplace_verify,
      "verify_marketplace_bundle_hash",
      params,
      text,
      context
    )
  end

  defp decision_attrs(:list_settings, _text, context) do
    action_decision_attrs(:list_settings, "list_settings", context)
  end

  defp decision_attrs({:read_setting, _key}, _text, context) do
    action_decision_attrs(:read_setting, "read_setting", context)
  end

  defp decision_attrs({:explain_setting, _key}, _text, context) do
    action_decision_attrs(:explain_setting, "explain_setting", context)
  end

  defp decision_attrs({:update_setting, _key, _value}, _text, context) do
    action_decision_attrs(:update_setting, "update_setting", context)
  end

  defp decision_attrs(:list_provider_profiles, _text, context) do
    action_decision_attrs(:list_provider_profiles, "list_provider_profiles", context)
  end

  defp decision_attrs({:set_provider_credential, _provider, _mode}, _text, context) do
    action_decision_attrs(:set_provider_credential, "set_provider_credential", context)
  end

  defp decision_attrs({:plan_package_install, params}, text, context) do
    %{
      intent: :plan_package_install,
      reason:
        "The prompt asks for a package installation plan without running a package manager.",
      selected_action: "plan_package_install",
      resource_access: package_resource_access(params, "plan_package_install"),
      alternatives: ["Review the package plan before asking for a confirmed install."],
      trace_metadata: %{package_params: params, source_text: text},
      context: context
    }
  end

  defp decision_attrs({:run_package_install, params}, text, context) do
    %{
      intent: :run_package_install,
      reason: "The prompt asks to run a package manager install.",
      selected_action: "run_package_install",
      resource_access: package_resource_access(params, "run_package_install"),
      alternatives: ["Ask for a package install plan instead of execution."],
      trace_metadata: %{package_params: params, source_text: text},
      context: context
    }
  end

  defp decision_attrs({:search_online_skills, params}, _text, context) do
    %{
      intent: :search_online_skills,
      reason: "The prompt asks to search a configured online skill source.",
      selected_action: "search_online_skills",
      resource_access:
        online_skill_resource_access(params, :online_skill_search, "search_online_skills"),
      alternatives: ["List local trusted skills instead."],
      context: context
    }
  end

  defp decision_attrs({:show_online_skill, params}, _text, context) do
    %{
      intent: :show_online_skill,
      reason: "The prompt asks to inspect one configured online skill source result.",
      selected_action: "show_online_skill",
      resource_access:
        online_skill_resource_access(params, :online_skill_detail, "show_online_skill"),
      alternatives: ["Search online skills first or inspect local trusted skills."],
      context: context
    }
  end

  defp decision_attrs({:import_remote_skill, url}, _text, context) do
    %{
      intent: :import_skill,
      reason: "The prompt asks to import a direct remote skill URL disabled and untrusted.",
      selected_action: "import_remote_skill",
      resource_access: remote_skill_import_resource_access(url, "import_remote_skill"),
      alternatives: ["Show or audit the skill before importing it."],
      context: context
    }
  end

  defp decision_attrs({:import_local_skill, path}, _text, context) do
    %{
      intent: :import_local_skill,
      reason: "The prompt asks to import a local skill directory disabled and untrusted.",
      selected_action: "import_local_skill",
      resource_access: local_skill_import_resource_access(path, "import_local_skill"),
      alternatives: ["Validate the local skill directory before importing it."],
      context: context
    }
  end

  defp decision_attrs({:run_skill_script, params}, text, context) do
    %{
      intent: :run_skill_script,
      reason: "The prompt asks to run an inventoried trusted skill script.",
      selected_action: "run_skill_script",
      resource_access: skill_script_resource_access(params, "run_skill_script"),
      alternatives: ["Activate or inspect the skill before running a script."],
      trace_metadata: %{script_params: params, source_text: text},
      context: context
    }
  end

  defp decision_attrs(:direct_answer, text, context) do
    skill_decision_attrs(:direct_answer, "direct-answer", "direct_answer", text, context)
  end

  defp skill_decision_attrs(intent, skill_name, action_name, text, context) do
    %{
      intent: intent,
      reason: "The prompt is handled by the trusted #{skill_name} skill/action path.",
      selected_skill: skill_name,
      selected_action: action_name,
      trace_metadata: %{source_text: text},
      context: context
    }
  end

  defp action_decision_attrs(intent, action_name, context) do
    %{
      intent: intent,
      reason: "The prompt is handled by a registered #{action_name} action.",
      selected_action: action_name,
      context: context
    }
  end

  defp marketplace_decision_attrs(intent, action_name, params, text, context) do
    %{
      intent: intent,
      reason: "The prompt matches the v0.45 Marketplace Lite phrase corpus.",
      selected_action: action_name,
      trace_metadata: %{source_text: text, marketplace_params: params},
      context: context
    }
  end

  defp run_route(:plan_shell_command, text, context) do
    run_skill_action(
      "plan-shell-command",
      "plan_shell_command",
      %{command: requested_command(text), source_text: text},
      text,
      context
    )
  end

  defp run_route(:run_shell_command, text, context) do
    case command_params_from_text(text) do
      {:ok, params} ->
        run_action("run_shell_command", Map.put(params, :source_text, text), text, context)

      {:error, _reason} ->
        run_route(:plan_shell_command, text, context)
    end
  end

  defp run_route(:external_network_request, text, context) do
    run_skill_action(
      "external-network-request",
      "external_network_request",
      %{request: network_request(text), source_text: text},
      text,
      context
    )
  end

  defp run_route({:url_summary, url}, text, context) do
    run_skill_action(
      "external-network-request",
      "external_network_request",
      %{
        url: url,
        method: "GET",
        operation_class: "summarize_url",
        downstream_consumer: "url_summarizer",
        postprocess: "summarize_url",
        source_text: text
      },
      text,
      context
    )
  end

  defp run_route({:document_url_inspection, url}, text, context) do
    run_skill_action(
      "external-network-request",
      "external_network_request",
      %{
        url: url,
        method: "GET",
        operation_class: "inspect_document",
        downstream_consumer: "document_extractor",
        postprocess: "inspect_document",
        source_text: text
      },
      text,
      context
    )
  end

  defp run_route({:plan_package_install, params}, text, context) do
    run_action("plan_package_install", Map.put(params, :source_text, text), text, context)
  end

  defp run_route({:run_package_install, params}, text, context) do
    run_action("run_package_install", Map.put(params, :source_text, text), text, context)
  end

  defp run_route({:search_online_skills, params}, text, context) do
    run_action("search_online_skills", params, text, context)
  end

  defp run_route({:show_online_skill, params}, text, context) do
    run_action("show_online_skill", params, text, context)
  end

  defp run_route({:import_remote_skill, url}, text, context) do
    run_action("import_remote_skill", %{url: url}, text, context)
  end

  defp run_route({:import_local_skill, path}, text, context) do
    run_action("import_local_skill", %{path: path}, text, context)
  end

  defp run_route({:run_skill_script, params}, text, context) do
    run_action("run_skill_script", Map.put(params, :source_text, text), text, context)
  end

  defp run_route({:unsupported_resource_workflow, workflow, resource}, text, context) do
    run_skill_action(
      "unsupported-resource-workflow",
      "unsupported_resource_workflow",
      %{workflow: to_string(workflow), source_text: text, resource: resource},
      text,
      context
    )
  end

  defp run_route({:mcp_list_tools, params}, text, context) do
    run_action("mcp_list_tools", params, text, context)
  end

  defp run_route({:mcp_list_resources, params}, text, context) do
    run_action("mcp_list_resources", params, text, context)
  end

  defp run_route({:mcp_read_resource, params}, text, context) do
    run_action("mcp_read_resource", params, text, context)
  end

  defp run_route({:mcp_call_tool, params}, text, context) do
    run_action("mcp_call_tool", params, text, context)
  end

  defp run_route({:local_file_inspection, path}, text, context) do
    run_skill_action(
      "unsupported-resource-workflow",
      "unsupported_resource_workflow",
      %{workflow: "read_local_path", source_text: text, resource: path},
      text,
      context
    )
  end

  defp run_route(:append_memory, text, context) do
    run_skill_action(
      "append-memory",
      "append_memory",
      %{memory: memory_text(text), source_text: text},
      text,
      context
    )
  end

  defp run_route({:append_personal_memory, memory}, text, context) do
    run_skill_action(
      "append-memory",
      "append_memory",
      %{memory: memory, source_text: text},
      text,
      context
    )
  end

  defp run_route({:read_recent_memory, query}, _text, context) do
    run_skill_action("read-recent-memory", "read_recent_memory", %{query: query}, query, context)
  end

  defp run_route({:read_skill, name}, text, context) do
    run_skill_action("read-skill", "read_skill", %{name: name}, text, context)
  end

  defp run_route({:activate_skill, name}, text, context) do
    run_action("activate_skill", %{name: name}, text, context, selected_skill: name)
  end

  defp run_route(:list_skills, text, context) do
    run_skill_action("list-skills", "list_skills", %{}, text, context)
  end

  defp run_route({:find_tools, query}, text, context) do
    run_action("find_tools", %{query: query}, text, context)
  end

  defp run_route({:discover_patterns, params}, text, context) do
    params =
      params
      |> Map.put_new(:user_id, context_value(context, :user_id))
      |> Map.put_new(:app_id, context_value(context, :active_app))

    run_action("discover_patterns", params, text, context)
  end

  defp run_route({:preview_plan, params}, text, context) do
    run_action("preview_plan", params, text, context)
  end

  defp run_route({:send_channel_message, params}, text, context) do
    run_action("send_channel_message", params, text, context)
  end

  defp run_route({:start_plan_run, params}, text, context) do
    run_action("start_plan_run", with_user(params, context), text, context)
  end

  defp run_route({:cancel_plan_run, params}, text, context) do
    params =
      params
      |> with_user(context)
      |> Map.put_new(:reason, "Cancelled from Plan/Build operator request.")

    run_action("cancel_plan_run", params, text, context)
  end

  defp run_route({:show_plan, params}, text, context) do
    run_action("show_objective", with_user(params, context), text, context)
  end

  defp run_route(:list_workflows, text, context) do
    run_action("list_workflows", %{}, text, context)
  end

  defp run_route(:list_plan_runs, text, context) do
    run_action("list_plan_runs", with_user(%{}, context), text, context)
  end

  defp run_route({:list_marketplace_entries, params}, text, context) do
    run_action("list_marketplace_entries", params, text, context)
  end

  defp run_route(:list_installed_marketplace_bundles, text, context) do
    run_action("list_installed_marketplace_bundles", %{}, text, context)
  end

  defp run_route({:install_marketplace_bundle, params}, text, context) do
    run_action("install_marketplace_bundle", params, text, context)
  end

  defp run_route({:rollback_marketplace_install, params}, text, context) do
    run_action("rollback_marketplace_install", params, text, context)
  end

  defp run_route({:verify_marketplace_bundle_hash, params}, text, context) do
    run_action("verify_marketplace_bundle_hash", params, text, context)
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
    run_skill_action("direct-answer", "direct_answer", %{text: text}, text, context)
  end

  defp run_route({:registry_action, action_name}, text, context) do
    execution_context = put_action_active_app(context, action_name)
    params = registry_action_params(action_name, text, execution_context)

    case {Map.get(execution_context, :decision),
          missing_required_action_params(action_name, params)} do
      {%Decision{} = decision, [_ | _] = missing} ->
        {:ok, router_missing_params_response(action_name, missing, execution_context, decision)}

      _ready ->
        run_action(action_name, params, text, execution_context)
    end
  end

  defp run_skill_action(skill_name, action_name, params, text, context) do
    case ActionPlan.build(skill_name, action_name, params, context) do
      {:ok, plan} ->
        run_action(plan.action_name, plan.params, text, context, ActionPlan.runner_context(plan))

      {:error, error} ->
        {:ok, skill_action_error_response(skill_name, action_name, error)}
    end
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

  defp put_action_active_app(context, action_name) do
    case Registry.capability(action_name) do
      {:ok, %{app_id: app_id}} when not is_nil(app_id) ->
        Map.put(context, :active_app, app_id)

      _other ->
        context
    end
  end

  defp registry_action_params(action_name, text, %{request: _request} = context) do
    %{}
    |> Map.merge(descriptor_params(action_name, context))
    |> maybe_put_text_derived_action_params(action_name, text)
    |> maybe_put_source_text_param(action_name, text)
  end

  defp maybe_put_text_derived_action_params(params, "external_network_request", text)
       when is_binary(text) do
    if present_param?(params, :request) or present_param?(params, :url) do
      params
    else
      Map.put(params, :request, network_request(text))
    end
  end

  defp maybe_put_text_derived_action_params(params, _action_name, _text), do: params

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp with_user(params, %{request: request}) do
    maybe_put_param(params, :user_id, Map.get(request, :user_id))
  end

  defp descriptor_params(action_name, request) do
    request
    |> Map.get(:decision)
    |> descriptor_params_from_decision(action_name)
  end

  defp descriptor_params_from_decision(
         %Decision{selected_action: action_name, trace_metadata: trace_metadata},
         action_name
       ) do
    # Engine-extracted slots flow through the same canonical seam (`:lenient`
    # key policy keeps unknown string keys for the descriptor-params map).
    trace_metadata
    |> Map.get(:extracted_slots, %{})
    |> Slots.to_params(:lenient)
  end

  defp descriptor_params_from_decision(_decision, _action_name), do: %{}

  defp maybe_put_source_text_param(params, action_name, text) when is_binary(text) do
    with {:ok, module} <- Registry.resolve(action_name),
         true <- function_exported?(module, :schema, 0),
         schema when is_list(schema) <- module.schema() do
      params
      |> maybe_put_required_source_param(schema, :prompt, text)
      |> maybe_put_required_source_param(schema, :text, text)
    else
      _other -> params
    end
  end

  defp maybe_put_required_source_param(params, schema, key, text) do
    if required_schema_key?(schema, key) and not present_param?(params, key) do
      Map.put(params, key, text)
    else
      params
    end
  end

  defp missing_required_action_params(action_name, params) do
    with {:ok, module} <- Registry.resolve(action_name),
         true <- function_exported?(module, :schema, 0),
         schema when is_list(schema) <- module.schema() do
      schema
      |> required_schema_keys()
      |> Enum.reject(&present_param?(params, &1))
    else
      _other -> []
    end
  end

  defp required_schema_keys(schema) do
    schema
    |> Enum.flat_map(fn
      {key, opts} when is_atom(key) and is_list(opts) ->
        if Keyword.get(opts, :required) == true, do: [key], else: []

      _entry ->
        []
    end)
  end

  defp required_schema_key?(schema, key) do
    Enum.any?(schema, fn
      {^key, opts} when is_list(opts) -> Keyword.get(opts, :required) == true
      _entry -> false
    end)
  end

  defp present_param?(params, key) do
    Enum.any?([key, Atom.to_string(key)], fn param_key ->
      case Map.get(params, param_key) do
        value when is_binary(value) -> String.trim(value) != ""
        nil -> false
        _value -> true
      end
    end)
  end

  defp format_param_names([one]), do: format_param_name(one)

  defp format_param_names([first, second]),
    do: "#{format_param_name(first)} and #{format_param_name(second)}"

  defp format_param_names(names) do
    {last, rest} = List.pop_at(names, -1)

    rest
    |> Enum.map(&format_param_name/1)
    |> Enum.join(", ")
    |> Kernel.<>(", and #{format_param_name(last)}")
  end

  defp format_param_name(name), do: name |> Atom.to_string() |> String.replace("_", " ")

  defp intent_handoff_decision?(%Decision{intent: intent})
       when intent in [:app_handoff, :clarify_intent],
       do: true

  defp intent_handoff_decision?(_decision), do: false

  defp intent_handoff_response(%Decision{} = decision, context) do
    decision = Engine.put_candidate_metadata(decision, context)

    case Handoff.from_decision(decision) do
      {:ok, handoff} ->
        # v0.54 (ADR 0060): no channel dead-end. Persist the proposal as a
        # clarification so the next reply ("yes" / naming the app action) binds,
        # while keeping the workspace proposal + intent_handoff metadata for the
        # web canvas surface.
        WorkspaceEmitters.intent_proposal(handoff, context.request)
        handoff_map = Handoff.to_map(handoff)
        options = handoff_clarify_options(decision)
        question = Handoff.message(handoff)
        persist_clarification(context, question, options)

        decision
        |> clarification_response(question, options)
        |> Map.put(:active_app, decision.active_app)
        |> Map.put(:intent_handoff, handoff_map)

      {:error, reason} ->
        Response.error("Unable to prepare app handoff: #{inspect(reason)}", reason,
          actions: [],
          diagnostics: decision.diagnostics
        )
    end
  end

  defp attach_decision({:ok, response}, %Decision{} = decision, context) do
    decision =
      decision
      |> sync_decision_after_response(response, context)
      |> Engine.put_candidate_metadata(context)

    approval_handoff = approval_handoff_for_response(response, decision)

    response =
      response
      |> Map.put(:decision, decision)
      |> Map.put(:active_app, decision.active_app)
      |> Map.put(:resource_access, ResourceAccess.to_maps(decision.resource_access))
      |> Map.put(:approval_handoff, approval_handoff)
      |> maybe_put_confirmation_id(approval_handoff)
      |> Map.update(:actions, [], &attach_approval_handoff(&1, approval_handoff))
      |> Map.update(:diagnostics, decision.diagnostics, &(decision.diagnostics ++ &1))
      |> maybe_frame_objective(decision, context)

    {:ok, response}
  end

  defp maybe_frame_objective(response, %Decision{} = decision, %{request: request} = context) do
    with false <- Map.has_key?(response, :objective),
         true <- objective_framing_candidate?(decision),
         {:ok, params} <- objective_frame_params(decision, request),
         permission_decision <- objective_write_decision(context, request),
         true <- PermissionGate.allowed?(permission_decision),
         {:ok, %{objective: objective}} <- ObjectivesEngine.frame_objective(params),
         {:ok, %{steps: steps} = proposed} <-
           ObjectivesEngine.propose_steps(%{
             objective_id: objective.id,
             text: request.text,
             intent_decision: %{
               text: request.text,
               selected_action: decision.selected_action,
               active_app: decision.active_app
             }
           }) do
      response
      |> Map.put(:objective, objective_response(objective, steps, proposed))
      |> Map.update(:actions, [], fn actions ->
        actions ++ [objective_action(objective, steps, context, permission_decision)]
      end)
    else
      false ->
        response

      true ->
        response

      {:error, reason} ->
        Map.update(response, :diagnostics, [], fn diagnostics ->
          diagnostics ++ [%{source: :objectives, error: inspect(reason)}]
        end)
    end
  end

  defp run_objective_route(text, %{request: request} = context, %Decision{} = decision) do
    permission_decision = objective_write_decision(context, request)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, params} <- objective_frame_params(decision, request),
         {:ok, %{objective: objective}} <- ObjectivesEngine.frame_objective(params),
         {:ok, %{steps: [step | _rest] = steps} = proposed} <-
           ObjectivesEngine.propose_steps(%{
             objective_id: objective.id,
             text: text,
             intent_decision: %{
               text: text,
               selected_action: decision.selected_action,
               active_app: decision.active_app
             }
           }),
         {:ok, authorization} <-
           ObjectivesEngine.authorize_step(%{
             step_id: step.id,
             input_signal_id: Map.get(request, :input_signal_id),
             trace_id: Map.get(request, :trace_id)
           }) do
      response = Map.get(authorization, :response, %{})
      authorized_step = Map.get(authorization, :step, step)
      updated_objective = Map.get(authorization, :objective, objective)
      steps = replace_objective_step(steps, authorized_step)

      {:ok,
       %{
         message: objective_route_message(updated_objective, authorized_step, response),
         status: Map.get(response, :status, :completed),
         confirmation: Map.get(response, :confirmation),
         confirmation_id: Map.get(response, :confirmation_id),
         permission_decision: Map.get(response, :permission_decision),
         actions:
           response
           |> Map.get(:actions, [])
           |> Kernel.++([
             objective_action(updated_objective, steps, context, permission_decision)
           ]),
         objective: objective_response(updated_objective, steps, proposed),
         diagnostics: []
       }}
    else
      false ->
        {:ok,
         Response.denied("Objective creation is not permitted for this request.",
           error: :permission_denied,
           permission_decision: permission_decision,
           actions: [
             %{
               name: "frame_objective",
               status: PermissionGate.response_status(permission_decision),
               permission: :objective_write,
               permission_decision: permission_decision
             }
           ],
           diagnostics: []
         )}

      {:error, reason} ->
        {:ok,
         Response.error("Unable to start objective: #{inspect(reason)}", reason,
           actions: [],
           diagnostics: [%{source: :objectives, error: inspect(reason)}]
         )}
    end
  end

  defp replace_objective_step(steps, %{id: id} = replacement) do
    Enum.map(steps, fn
      %{id: ^id} -> replacement
      step -> step
    end)
  end

  defp objective_route_message(objective, step, %{status: :needs_confirmation} = response) do
    confirmation_id = Map.get(response, :confirmation_id) || step.confirmation_id

    "Started objective #{objective.title}. Confirmation required for step #{step.id}: #{confirmation_id}."
  end

  defp objective_route_message(objective, step, response) do
    "Started objective #{objective.title}. Step #{step.id} is #{Map.get(response, :status, step.status)}."
  end

  defp objective_framing_candidate?(%Decision{
         active_app: :stocksage,
         selected_action: "run_analysis"
       }),
       do: true

  defp objective_framing_candidate?(_decision), do: false

  defp objective_frame_params(decision, request) do
    case stock_symbols_from_text(request.text) do
      [] ->
        {:error, :missing_objective_entity}

      [symbol] ->
        {:ok,
         %{
           user_id: request.user_id,
           source_thread_id: Map.get(request, :thread_id),
           session_id: Map.get(request, :session_id),
           active_app: decision.active_app,
           title: "Analyze #{symbol}",
           objective: "Complete a StockSage analysis for #{symbol}.",
           source_intent: request.text,
           acceptance_criteria: %{
             "min_completed_steps" => 1,
             "required" => [
               %{
                 "kind" => "step_completed_with_action",
                 "action" => "StockSage.Actions.RunAnalysis",
                 "params_match" => %{"ticker" => symbol},
                 "min_count" => 1
               }
             ],
             "needs_more_when" => [
               %{"kind" => "completed_step_count_below", "value" => 1}
             ],
             "summary" => "One completed StockSage RunAnalysis step for #{symbol}."
           }
         }}

      [first, second | _rest] ->
        {:ok,
         %{
           user_id: request.user_id,
           source_thread_id: Map.get(request, :thread_id),
           session_id: Map.get(request, :session_id),
           active_app: decision.active_app,
           title: "Compare #{first} and #{second}",
           objective: "Complete StockSage analyses for #{first} and #{second}.",
           source_intent: request.text,
           acceptance_criteria: %{
             "min_completed_steps" => 2,
             "required" => [
               %{
                 "kind" => "step_completed_with_action",
                 "action" => "StockSage.Actions.RunAnalysis",
                 "params_match" => %{"ticker" => first},
                 "min_count" => 1
               },
               %{
                 "kind" => "step_completed_with_action",
                 "action" => "StockSage.Actions.RunAnalysis",
                 "params_match" => %{"ticker" => second},
                 "min_count" => 1
               }
             ],
             "needs_more_when" => [
               %{"kind" => "completed_step_count_below", "value" => 2}
             ],
             "summary" => "Completed StockSage RunAnalysis steps for #{first} and #{second}."
           }
         }}
    end
  end

  defp stock_symbols_from_text(text) do
    ~r/\b[A-Z]{1,5}\b/
    |> Regex.scan(text)
    |> Enum.map(&List.first/1)
    |> Enum.uniq()
  end

  defp objective_response(objective, steps, proposed) do
    %{
      id: objective.id,
      status: objective.status,
      title: objective.title,
      active_app: objective.active_app,
      step_count: length(steps),
      steps: Enum.map(steps, &objective_step_response/1),
      continuation: Map.get(proposed, :continuation)
    }
  end

  defp objective_step_response(step) do
    %{
      id: step.id,
      status: step.status,
      kind: step.kind,
      candidate_action: step.candidate_action,
      parent_step_id: step.parent_step_id,
      confirmation_id: step.confirmation_id
    }
  end

  defp objective_write_decision(context, request) do
    context =
      context
      |> Map.put(:user_id, Map.get(request, :user_id))
      |> Map.put(:operator_id, Map.get(request, :operator_id))
      |> Map.delete(:selected_action)

    PermissionGate.authorize(:objective_write, context)
  end

  defp objective_action(objective, steps, context, permission_decision) do
    %{
      name: "frame_objective",
      status: :proposed,
      permission: :objective_write,
      permission_decision: permission_decision,
      objective_id: objective.id,
      step_count: length(steps),
      user_id: get_in(context, [:request, :user_id]),
      active_app: objective.active_app
    }
  end

  defp sync_decision_after_response(%Decision{} = decision, response, context) do
    confirmation =
      case Map.get(response, :status) do
        :needs_confirmation -> :pending
        :unsupported -> :unsupported
        :denied -> decision.confirmation
        _status -> decision.confirmation
      end

    trace_metadata =
      decision.trace_metadata
      |> Map.put(:confirmation, confirmation)
      |> put_if_present(:confirmation_id, Map.get(response, :confirmation_id))
      |> put_if_present(:response_status, Map.get(response, :status))

    approval_handoff = maybe_approval_handoff(confirmation, decision, response, context)

    %{
      decision
      | confirmation: confirmation,
        approval_handoff: approval_handoff,
        trace_metadata: trace_metadata
    }
  end

  defp maybe_approval_handoff(:pending, decision, response, context) do
    decision
    |> ApprovalHandoff.pending(response, context)
    |> ApprovalHandoff.to_map()
  end

  defp maybe_approval_handoff(_confirmation, _decision, _response, _context), do: nil

  defp approval_handoff_for_response(response, %Decision{} = decision) do
    response
    |> field(:approval_handoff)
    |> normalize_approval_handoff(response)
    |> case do
      nil -> normalize_approval_handoff(decision.approval_handoff, response)
      handoff -> handoff
    end
  end

  defp normalize_approval_handoff(nil, _response), do: nil

  defp normalize_approval_handoff(handoff, response) when is_map(handoff) do
    handoff = ApprovalHandoff.to_map(handoff)

    case confirmation_id(handoff) || confirmation_id(response) do
      nil -> handoff
      id -> Map.put_new(handoff, :confirmation_id, id)
    end
  end

  defp normalize_approval_handoff(_handoff, _response), do: nil

  defp maybe_put_confirmation_id(response, nil), do: response

  defp maybe_put_confirmation_id(response, handoff) do
    case field(response, :confirmation_id) || confirmation_id(handoff) do
      nil -> response
      id -> Map.put_new(response, :confirmation_id, id)
    end
  end

  defp attach_approval_handoff(actions, nil), do: actions
  defp attach_approval_handoff([], _handoff), do: []

  defp attach_approval_handoff(actions, handoff) do
    if Enum.any?(actions, &(field(&1, :approval_handoff) != nil)) do
      actions
    else
      target_name = approval_target_name(handoff)
      attach_to_matching_action(actions, handoff, target_name)
    end
  end

  defp attach_to_matching_action(actions, handoff, nil) do
    [action | rest] = actions
    [Map.put(action, :approval_handoff, handoff) | rest]
  end

  defp attach_to_matching_action(actions, handoff, target_name) do
    {updated, attached?} =
      Enum.map_reduce(actions, false, fn action, attached? ->
        if not attached? and to_string(field(action, :name, "")) == target_name do
          {Map.put(action, :approval_handoff, handoff), true}
        else
          {action, attached?}
        end
      end)

    if attached? do
      updated
    else
      attach_to_matching_action(actions, handoff, nil)
    end
  end

  defp approval_target_name(handoff) do
    target = field(handoff, :target_action, %{}) || %{}
    action = field(target, :action, %{}) || %{}

    case field(action, :name) || field(target, :name) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp confirmation_id(value) when is_map(value) do
    field(value, :confirmation_id) ||
      value |> field(:approval_handoff, %{}) |> field(:confirmation_id) ||
      value |> field(:confirmation, %{}) |> field(:id) ||
      confirmation_id_from_actions(field(value, :actions, []))
  end

  defp confirmation_id(_value), do: nil

  defp confirmation_id_from_actions(actions) when is_list(actions) do
    Enum.find_value(actions, fn action ->
      field(action, :confirmation_id) ||
        action |> field(:metadata, %{}) |> field(:confirmation_id) ||
        action |> field(:approval_handoff, %{}) |> field(:confirmation_id)
    end)
  end

  defp confirmation_id_from_actions(_actions), do: nil

  defp decision_refusal_response(%Decision{} = decision) do
    decision = Engine.put_candidate_metadata(decision)
    permission_decision = Decision.authorization_decision(decision)

    reason =
      permission_reason(permission_decision) || decision.risk_summary || "permission denied"

    denial_reason = refusal_reason(decision, permission_decision)

    %{
      message: refusal_message(decision, reason),
      status: :denied,
      decision: decision,
      resource_access: ResourceAccess.to_maps(decision.resource_access),
      approval_handoff: nil,
      diagnostics: decision.diagnostics,
      actions: [
        %{
          name: decision.selected_action || "none",
          status: :denied,
          permission: decision.permission,
          permission_decision: permission_decision,
          execution: :not_started,
          denial_reason: denial_reason,
          resource_access: ResourceAccess.to_maps(decision.resource_access),
          decision: Decision.to_map(decision)
        }
      ]
    }
  end

  defp invalid_decision_response(reason, text, context) do
    {:ok, decision} =
      Decision.new(%{
        intent: :invalid_intent_decision,
        confidence: 0.0,
        reason: "The intent route could not be validated.",
        selected_action: "direct_answer",
        selected_skill: "direct-answer",
        alternatives: ["Try a narrower prompt with an explicit action."],
        diagnostics: [%{source: :intent_decision, error: inspect(reason)}],
        trace_metadata: %{source_text: text},
        context: context
      })

    decision = Engine.put_candidate_metadata(decision)

    %{
      message: "I could not validate that intent decision: #{inspect(reason)}.",
      status: :denied,
      decision: decision,
      resource_access: [],
      approval_handoff: nil,
      diagnostics: decision.diagnostics,
      actions: [
        %{
          name: "direct_answer",
          status: :denied,
          permission: :read_only,
          execution: :not_started,
          decision: Decision.to_map(decision)
        }
      ]
    }
  end

  defp skill_action_error_response(skill_name, action_name, error) do
    %{
      message:
        "I could not use skill #{inspect(skill_name)} for action #{inspect(action_name)}: #{error.message}",
      status: :denied,
      error: error,
      actions: [
        %{
          name: action_name,
          status: :denied,
          selected_skill: skill_name,
          error: error
        }
      ]
    }
  end

  defp skill_import_route(text, normalized) do
    url = first_url(text)
    path = local_path_after_import(text)

    cond do
      String.contains?(normalized, "skill") &&
        Regex.match?(~r/\b(import|install|add)\b/, normalized) &&
          is_binary(url) ->
        {:import_remote_skill, url}

      String.contains?(normalized, "skill") &&
        Regex.match?(~r/\b(import|install|add)\b/, normalized) &&
          is_binary(path) ->
        {:import_local_skill, path}

      true ->
        nil
    end
  end

  defp skill_script_route(text, normalized) do
    if Regex.match?(~r/\b(run|execute)\b.*\bskill\s+script\b/, normalized) do
      {:run_skill_script, skill_script_params(text)}
    end
  end

  defp package_route(text, normalized) do
    cond do
      Regex.match?(~r/^\s*(run|execute)\s+package\s+install\b/i, text) ->
        {:run_package_install, package_params(text)}

      Regex.match?(~r/^\s*(npm|pnpm|yarn|pip)\s+install\b/i, text) ->
        {:plan_package_install, package_params(text)}

      Regex.match?(
        ~r/\b(plan|install|add)\b.*\b(package|dependency|npm package|pip package)\b/i,
        text
      ) ->
        {:plan_package_install, package_params(text)}

      String.contains?(normalized, "package install") ->
        {:plan_package_install, package_params(text)}

      true ->
        nil
    end
  end

  defp online_skill_route(text, normalized) do
    cond do
      Regex.match?(~r/\b(search|find)\b.*\bonline\s+skills?\b/i, text) ->
        {:search_online_skills, %{query: online_skill_query(text), source: "skills_sh"}}

      Regex.match?(~r/\b(show|inspect|read)\b.*\bonline\s+skill\b/i, text) ->
        {:show_online_skill, online_skill_detail_params(text)}

      String.contains?(normalized, "skills.sh") && Regex.match?(~r/\bsearch|find\b/i, text) ->
        {:search_online_skills, %{query: online_skill_query(text), source: "skills_sh"}}

      true ->
        nil
    end
  end

  defp uri_consumer_route(text, normalized) do
    url = first_url(text)
    local_path = local_file_path(text)

    cond do
      is_binary(url) && url_summary_request?(normalized) ->
        {:url_summary, url}

      is_binary(url) && remote_document_request?(normalized) ->
        {:document_url_inspection, url}

      is_binary(local_path) && local_file_inspection_request?(normalized) ->
        {:local_file_inspection, local_path}

      true ->
        nil
    end
  end

  defp command_resource_access(text, target_action, mode) do
    with {:ok, params} <- command_params_from_text(text) do
      cwd = Map.get(params, :cwd, File.cwd!())

      [
        %{
          resource_uri: ResourceURI.file!(cwd),
          origin_kind: :local_path,
          canonical_id: cwd,
          operation_class: :run_shell_command,
          access_mode: if(mode == :prospective, do: :read, else: :execute),
          scope: Scope.directory_subtree(cwd),
          downstream_consumer: :shell_runner,
          target_action: target_action,
          output_cap: 65_536,
          allowed_approval_scopes: [:once, :exact_resource, :local_directory],
          metadata: %{
            executable: Map.get(params, :executable),
            args: Map.get(params, :args, []),
            posture: mode
          }
        }
      ]
    else
      {:error, reason} ->
        [
          %{
            resource_uri: ResourceURI.file!(File.cwd!()),
            operation_class: :run_shell_command,
            access_mode: :read,
            scope: Scope.directory_subtree(File.cwd!()),
            downstream_consumer: :shell_runner,
            target_action: target_action,
            diagnostics: [%{source: :command_parser, error: inspect(reason)}],
            metadata: %{posture: mode}
          }
        ]
    end
  end

  defp url_resource_access(text, operation_class, target_action) do
    case first_url(text) do
      nil ->
        []

      url ->
        [
          %{
            resource_uri: ResourceURI.url!(url),
            operation_class: operation_class,
            access_mode: access_mode_for_operation(operation_class),
            scope: Scope.exact_url(url),
            display_uri: url,
            downstream_consumer: downstream_consumer_for_operation(operation_class),
            target_action: target_action,
            expected_content_kind: expected_content_kind(operation_class),
            byte_cap: 1_048_576,
            redirect_policy: :no_redirects,
            retry_policy: :none,
            allowed_approval_scopes: [:once, :exact_resource, :url_prefix]
          }
        ]
    end
  end

  defp mcp_resource_access(%{server_id: server_id, uri: uri}, target_action)
       when is_binary(server_id) and is_binary(uri) do
    [
      %{
        resource_uri: ResourceURI.mcp!(server_id, uri),
        origin_kind: :mcp_resource,
        operation_class: :mcp_resource_read,
        access_mode: :read,
        scope: Scope.mcp_server(server_id),
        display_uri: uri,
        downstream_consumer: :mcp_resource_reader,
        target_action: target_action,
        unsupported?: false,
        allowed_approval_scopes: [:once, :mcp_server]
      }
    ]
  end

  defp mcp_resource_access(_params, _target_action), do: []

  defp mcp_tool_resource_access(%{server_id: server_id, tool_name: tool_name}, target_action)
       when is_binary(server_id) and is_binary(tool_name) do
    [
      %{
        resource_uri: ResourceURI.mcp!(server_id, "tools/" <> tool_name),
        origin_kind: :mcp_resource,
        operation_class: :mcp_tool_call,
        access_mode: :call,
        scope: Scope.mcp_tool("#{server_id}:#{tool_name}"),
        downstream_consumer: :mcp_tool_runner,
        target_action: target_action,
        unsupported?: false,
        allowed_approval_scopes: [:once]
      }
    ]
  end

  defp mcp_tool_resource_access(_params, _target_action), do: []

  defp workflow_resource_access(:summarize_url, resource, _text) when is_binary(resource) do
    url_resource_access(resource, :summarize_url, "unsupported_resource_workflow")
  end

  defp workflow_resource_access(:inspect_document, resource, _text) when is_binary(resource) do
    url_resource_access(resource, :inspect_document, "unsupported_resource_workflow")
  end

  defp workflow_resource_access(:document_extraction, resource, _text) when is_binary(resource) do
    url_resource_access(resource, :inspect_document, "unsupported_resource_workflow")
  end

  defp workflow_resource_access(:read_local_path, resource, _text) when is_binary(resource) do
    local_file_resource_access(resource, "unsupported_resource_workflow")
  end

  defp workflow_resource_access(:unsupported_uri_scheme, resource, _text)
       when is_binary(resource) do
    [
      %{
        resource_uri: ResourceURI.normalize!(resource),
        operation_class: :external_service_request,
        access_mode: :fetch,
        scope: Scope.exact_url(resource),
        display_uri: resource,
        downstream_consumer: :unsupported_resource_workflow,
        target_action: "unsupported_resource_workflow",
        unsupported?: true,
        diagnostics: [%{source: :intent_agent, reason: :unsupported_uri_scheme}]
      }
    ]
  end

  defp workflow_resource_access(_workflow, resource, text) do
    case resource || first_url(text) do
      nil -> []
      url -> url_resource_access(url, :external_service_request, "unsupported_resource_workflow")
    end
  end

  defp package_resource_access(params, target_action) do
    manager = Map.get(params, :manager, "npm")
    packages = Map.get(params, :packages, [])
    project_root = Map.get(params, :project_root) || Map.get(params, :cwd) || File.cwd!()

    package_refs =
      Enum.map(packages, fn package ->
        %{
          resource_uri: ResourceURI.package!(manager, package),
          operation_class: :package_install,
          access_mode: :install,
          scope: Scope.source_profile(manager),
          source: manager,
          downstream_consumer: :package_manager,
          target_action: target_action,
          output_cap: 65_536,
          allowed_approval_scopes: [:once, :exact_resource],
          metadata: %{package: package, save_mode: Map.get(params, :save_mode)}
        }
      end)

    target_ref = %{
      resource_uri: ResourceURI.file!(project_root),
      operation_class: :package_install,
      access_mode: :write,
      scope: Scope.package_target_root(project_root),
      source: manager,
      downstream_consumer: :package_manager,
      target_action: target_action,
      allowed_approval_scopes: [:once, :local_directory],
      metadata: %{target_root: project_root}
    }

    package_refs ++ [target_ref]
  end

  defp local_file_resource_access(path, target_action) do
    canonical = Path.expand(path)

    [
      %{
        resource_uri: ResourceURI.file!(canonical),
        origin_kind: :local_path,
        canonical_id: canonical,
        operation_class: :read_local_path,
        access_mode: :read,
        scope: Scope.exact_file(canonical),
        display_uri: "file://#{canonical}",
        downstream_consumer: :bounded_file_reader,
        target_action: target_action,
        expected_content_kind: :local_file,
        byte_cap: 262_144,
        output_cap: 65_536,
        allowed_approval_scopes: [:once, :exact_resource, :local_directory],
        diagnostics: [%{source: :intent_agent, reason: :bounded_file_reader_unavailable}],
        metadata: %{posture: :unavailable, shell_fallback?: false}
      }
    ]
  end

  defp online_skill_resource_access(params, operation_class, target_action) do
    source = Map.get(params, :source, "skills_sh")

    Ref.online_skill_source(
      %{id: source, max_listing_results: 20, max_download_bytes: 1_048_576},
      operation_class,
      Map.drop(params, [:source])
    )
    |> Enum.map(
      &Map.merge(&1, %{
        target_action: target_action,
        allowed_approval_scopes: [:once, :exact_resource]
      })
    )
  end

  defp remote_skill_import_resource_access(url, target_action) do
    [
      %{
        resource_uri: ResourceURI.url!(url),
        operation_class: :import_skill,
        access_mode: :import,
        scope: Scope.exact_url(url),
        display_uri: url,
        downstream_consumer: :skill_importer,
        target_action: target_action,
        expected_content_kind: :agent_skill,
        parser: :agent_skill_parser,
        byte_cap: 1_048_576,
        allowed_approval_scopes: [:once, :exact_resource, :url_prefix],
        metadata: %{trust_after_import: :disabled_untrusted}
      }
    ]
  end

  defp local_skill_import_resource_access(path, target_action) do
    canonical = Path.expand(path)

    [
      %{
        resource_uri: ResourceURI.file!(canonical),
        operation_class: :import_local_skill,
        access_mode: :import,
        scope: Scope.directory_subtree(canonical),
        downstream_consumer: :skill_importer,
        target_action: target_action,
        expected_content_kind: :agent_skill_directory,
        parser: :agent_skill_parser,
        allowed_approval_scopes: [:once, :exact_resource, :local_directory],
        metadata: %{trust_after_import: :disabled_untrusted}
      }
    ]
  end

  defp skill_script_resource_access(params, target_action) do
    skill_name = Map.get(params, :skill_name)
    script_path = Map.get(params, :script_path)
    script_id = Enum.join(Enum.reject([skill_name, script_path], &blank?/1), ":")
    cwd = Map.get(params, :cwd, File.cwd!())

    [
      %{
        resource_uri: ResourceURI.skill_resource!(script_id),
        operation_class: :run_skill_script,
        access_mode: :execute,
        scope: Scope.skill_resource_id(script_id),
        downstream_consumer: :skill_script_runner,
        target_action: target_action,
        output_cap: 65_536,
        digest: Map.get(params, :expected_sha256),
        allowed_approval_scopes: [:once, :exact_resource],
        metadata: %{skill_name: skill_name, script_path: script_path}
      },
      %{
        resource_uri: ResourceURI.file!(cwd),
        operation_class: :run_skill_script,
        access_mode: :execute,
        scope: Scope.directory_subtree(cwd),
        downstream_consumer: :skill_script_runner,
        target_action: target_action,
        allowed_approval_scopes: [:once, :local_directory]
      }
    ]
  end

  defp unsupported_alternatives(:summarize_url),
    do: ["Fetch approval and summarization require the v0.11 URI consumer flow."]

  defp unsupported_alternatives(:inspect_document),
    do: ["Provide extracted text directly or wait for a registered document extractor."]

  defp unsupported_alternatives(:read_local_path),
    do: ["Paste the relevant text directly; v0.11 has no generic local file reader."]

  defp unsupported_alternatives(:unsupported_uri_scheme),
    do: ["Use a supported registered action or wait for a future MCP/agent adapter."]

  defp unsupported_alternatives(_workflow),
    do: ["Use an already registered v0.08-v0.10 capability or a narrower prompt."]

  defp access_mode_for_operation(:summarize_url), do: :summarize
  defp access_mode_for_operation(:inspect_document), do: :read
  defp access_mode_for_operation(_operation_class), do: :fetch

  defp downstream_consumer_for_operation(:summarize_url), do: :url_summarizer
  defp downstream_consumer_for_operation(:inspect_document), do: :document_extractor
  defp downstream_consumer_for_operation(_operation_class), do: :req_http

  defp expected_content_kind(:summarize_url), do: :html_or_text
  defp expected_content_kind(:inspect_document), do: :document
  defp expected_content_kind(_operation_class), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp permission_reason(%{reason: reason}), do: reason
  defp permission_reason(%{"reason" => reason}), do: reason
  defp permission_reason(_decision), do: nil

  defp refusal_message(%Decision{selected_action: "run_shell_command"}, reason) do
    "Shell command execution was denied before action execution: #{reason}."
  end

  defp refusal_message(%Decision{selected_action: action}, reason) do
    "Intent decision refused #{action || "the selected action"}: #{reason}."
  end

  defp refusal_reason(%Decision{permission: :command_execute}, _permission_decision),
    do: :local_execution_disabled

  defp refusal_reason(%Decision{permission: permission}, %{reason: reason}),
    do: reason || permission

  defp refusal_reason(%Decision{permission: permission}, _permission_decision), do: permission

  defp command_request?(text, context) do
    if job_channel?(context) do
      explicit_shell_command_request?(text)
    else
      command_request?(text)
    end
  end

  defp command_request?(text) do
    Regex.match?(~r/^\s*(run|execute|exec|shell|terminal)\b/, text) ||
      String.contains?(text, " shell command") ||
      String.contains?(text, " command line") ||
      Regex.match?(~r/\brm\s+-/, text)
  end

  defp explicit_shell_command_request?(text) do
    Regex.match?(~r/^\s*(shell|terminal)\b/, text) ||
      String.contains?(text, " shell command") ||
      String.contains?(text, " command line") ||
      Regex.match?(~r/\brm\s+-/, text)
  end

  defp job_channel?(%{request: request}) when is_map(request) do
    case Map.get(request, :channel) || Map.get(request, "channel") do
      :job -> true
      "job" -> true
      _other -> false
    end
  end

  defp unsupported_resource_workflow_route(text, normalized) do
    cond do
      unsupported_uri_scheme_request?(normalized) ->
        {:unsupported_resource_workflow, :unsupported_uri_scheme, resource_hint(text)}

      url_summary_request?(normalized) ->
        {:unsupported_resource_workflow, :summarize_url, resource_hint(text)}

      document_extraction_request?(normalized) ->
        {:unsupported_resource_workflow, :document_extraction, resource_hint(text)}

      document_inspection_request?(normalized) ->
        {:unsupported_resource_workflow, :inspect_document, resource_hint(text)}

      broad_web_request?(normalized) ->
        {:unsupported_resource_workflow, :web_browsing, resource_hint(text)}

      channel_approval_handoff_request?(normalized) ->
        {:unsupported_resource_workflow, :channel_approval_handoff, resource_hint(text)}

      true ->
        nil
    end
  end

  defp mcp_route(text, normalized) do
    cond do
      mcp_list_tools_request?(normalized) ->
        {:mcp_list_tools, %{server_id: mcp_server_hint(text)}}

      mcp_list_resources_request?(normalized) ->
        {:mcp_list_resources, %{server_id: mcp_server_hint(text)}}

      mcp_tool_call_request?(normalized) ->
        {:mcp_call_tool, mcp_tool_params(text)}

      mcp_uri = first_mcp_uri(text) ->
        {:mcp_read_resource, mcp_resource_params(mcp_uri)}

      true ->
        nil
    end
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

  defp unsupported_uri_scheme_request?(text) do
    String.contains?(text, "agent://") ||
      String.contains?(text, "agent+https://") ||
      Regex.match?(~r/\bdelegate\s+.+\bagent\b/, text)
  end

  defp mcp_list_tools_request?(text) do
    String.contains?(text, "mcp") and
      Regex.match?(~r/\b(list|show)\b.*\btools\b|\btools\b.*\b(list|show)\b/, text)
  end

  defp mcp_list_resources_request?(text) do
    String.contains?(text, "mcp") and
      Regex.match?(~r/\b(list|show)\b.*\bresources\b|\bresources\b.*\b(list|show)\b/, text)
  end

  defp mcp_tool_call_request?(text) do
    String.contains?(text, "mcp") and Regex.match?(~r/\b(call|run|invoke)\b.*\btool\b/, text)
  end

  defp url_summary_request?(text) do
    String.contains?(text, "http") &&
      Regex.match?(~r/\b(summarize|summary|summarise|summarisation)\b/, text)
  end

  defp document_extraction_request?(text) do
    Regex.match?(~r/\b(extract|parse)\b.*\b(document|pdf|docx|xlsx|pptx|file)\b/, text) ||
      Regex.match?(~r/\b(document|pdf|docx|xlsx|pptx|file)\b.*\b(extract|parse)\b/, text)
  end

  defp document_inspection_request?(text) do
    Regex.match?(~r/\b(inspect|review|read|check)\b.*\b(document|pdf|docx|xlsx|pptx)\b/, text) ||
      Regex.match?(~r/\b(document|pdf|docx|xlsx|pptx)\b.*\b(inspect|review|read|check)\b/, text)
  end

  defp remote_document_request?(text) do
    document_extraction_request?(text) || document_inspection_request?(text)
  end

  defp local_file_inspection_request?(text) do
    (String.contains?(text, "file://") ||
       Regex.match?(~r/\b(local\s+file|file|path)\b/, text)) &&
      Regex.match?(~r/\b(read|inspect|review|check|summarize|summarise)\b/, text)
  end

  defp broad_web_request?(text) do
    String.contains?(text, "crawl ") ||
      String.contains?(text, "crawler") ||
      String.contains?(text, "browse the web") ||
      String.contains?(text, "browse internet") ||
      String.contains?(text, "research online") ||
      String.contains?(text, "research the internet") ||
      String.contains?(text, "search the internet")
  end

  defp channel_approval_handoff_request?(text) do
    Regex.match?(~r/\b(telegram|email|sms)\b.*\b(approval|approve|handoff)\b/, text) ||
      Regex.match?(~r/\b(channel-native|channel native)\b.*\bapproval/, text)
  end

  defp resource_hint(text) do
    cond do
      match = Regex.run(~r/(agent\+https:\/\/[^\s<>"']+)/i, text) ->
        List.first(match)

      match = Regex.run(~r/((?:https?|mcp|agent):\/\/[^\s<>"']+)/i, text) ->
        List.first(match)

      true ->
        nil
    end
  end

  defp first_mcp_uri(text) do
    case Regex.run(~r/(mcp:\/\/[^\s<>"']+)/i, text) do
      [uri | _rest] -> uri
      _other -> nil
    end
  end

  defp mcp_resource_params(uri) do
    parsed = URI.parse(uri)

    %{
      server_id: parsed.host,
      uri: parsed.path |> to_string() |> String.trim_leading("/") |> URI.decode(),
      resource_uri: uri
    }
  end

  defp mcp_tool_params(text) do
    %{
      server_id: mcp_server_hint(text),
      tool_name: mcp_tool_hint(text),
      arguments: %{}
    }
  end

  defp mcp_server_hint(text) do
    cond do
      uri = first_mcp_uri(text) ->
        URI.parse(uri).host

      match = Regex.run(~r/\b([A-Za-z0-9_-]+)\s+mcp\s+server\b/i, text) ->
        Enum.at(match, 1)

      match = Regex.run(~r/\bmcp\s+server\s+([A-Za-z0-9_-]+)\b/i, text) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp mcp_tool_hint(text) do
    cond do
      uri = first_mcp_uri(text) ->
        uri
        |> URI.parse()
        |> Map.get(:path)
        |> to_string()
        |> String.trim_leading("/")
        |> URI.decode()
        |> String.replace_prefix("tools/", "")

      match = Regex.run(~r/\btool\s+([A-Za-z0-9_.-]+)\b/i, text) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp mcp_decision_attrs(intent, action_name, reason, params, resource_access, text, context) do
    %{
      intent: intent,
      reason: reason,
      selected_action: action_name,
      resource_access: resource_access,
      alternatives: ["Configure the MCP server first if this route reports it is missing."],
      trace_metadata: %{source_text: text, extracted_slots: params},
      context: context
    }
  end

  defp local_file_path(text) do
    cond do
      match = Regex.run(~r/(file:\/\/[^\s<>"']+)/i, text) ->
        match
        |> List.first()
        |> String.trim_trailing(".,)")
        |> path_from_file_uri()

      match =
          Regex.run(
            ~r/\b(?:file|path|document)\s+(?:at\s+|from\s+|is\s+)?["']?([~\/.][^"'\s,;]+)["']?/i,
            text
          ) ->
        match |> Enum.at(1) |> String.trim_trailing(".,)")

      match =
          Regex.run(~r/([~\/.][^\s,;]+\.(?:txt|md|pdf|docx|xlsx|pptx|csv|json|exs?|heex))/i, text) ->
        match |> Enum.at(1) |> String.trim_trailing(".,)")

      true ->
        nil
    end
  end

  defp path_from_file_uri(uri) do
    case ResourceURI.path_from_file_uri(uri) do
      {:ok, path} -> path
      {:error, _reason} -> uri
    end
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

  # "what can you do", "what allbert can do locally", "what can it do",
  # "understand what you can do" — subject and word order both vary.
  @capability_question_re ~r/what\s+(?:can\s+)?(?:you|allbert|it|this)\s+(?:can\s+|could\s+)?do(?:es)?\b/

  defp capability_request?(text) do
    Regex.match?(@capability_question_re, text) ||
      String.contains?(text, "available skills") ||
      String.contains?(text, "skills are available") ||
      String.contains?(text, "what skills") ||
      String.contains?(text, "list skills") ||
      String.contains?(text, "skills you can inspect") ||
      String.contains?(text, "capabilities") ||
      String.contains?(text, "what actions")
  end

  defp tool_discovery_request?(text) do
    normalized = String.downcase(text)

    Enum.any?(
      [
        "find a tool",
        "find tools",
        "find a server",
        "find server",
        "what tools",
        "which tools",
        "tools do i have",
        "tool for",
        "server for",
        "mcp server"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp tool_discovery_query(text) do
    case Regex.run(~r/\bfor(?:\s+working\s+with)?\s+(.+?)\??\s*$/i, text, capture: :all_but_first) do
      [query] -> query |> String.trim() |> String.trim_trailing("?")
      _other -> text
    end
  end

  defp self_improvement_enabled? do
    case Settings.get("self_improvement.enabled") do
      {:ok, true} -> true
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp context_value(context, key) do
    Map.get(context, key, Map.get(context, Atom.to_string(key)))
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
    |> String.replace(~r/^\s*(please\s+)?(run|execute|exec|shell|terminal)\s+/i, "")
    |> String.trim()
  end

  defp command_params_from_text(text) do
    text
    |> requested_command()
    |> split_command_text()
    |> case do
      [executable | args] -> {:ok, %{executable: executable, args: args, cwd: File.cwd!()}}
      [] -> {:error, :empty_command}
    end
  end

  defp split_command_text(command) do
    OptionParser.split(command)
  rescue
    _exception -> []
  end

  defp network_request(text) do
    text
    |> String.replace(~r/^\s*(please\s+)?(fetch|browse|download|call|post|get)\s+/i, "")
    |> String.trim()
  end

  defp first_url(text) do
    case Regex.run(~r/(https?:\/\/[^\s<>"']+)/i, text) do
      [url | _rest] -> String.trim_trailing(url, ".,)")
      _match -> nil
    end
  end

  defp local_path_after_import(text) do
    case Regex.run(~r/\b(?:from|directory|dir|folder|path)\s+([~\/.][^\n\r]*)$/i, text) do
      [_, path] -> path |> String.trim() |> String.trim("\"'")
      _match -> nil
    end
  end

  defp skill_script_params(text) do
    match =
      Regex.run(
        ~r/skill\s+script\s+([a-z0-9_.-]+)(?::|\s+)([^\s]+)(?:\s+(.+))?/i,
        text
      )

    case match do
      [_, skill_name, script_path, args] ->
        %{
          skill_name: skill_name,
          script_path: script_path,
          args: split_args(args),
          cwd: File.cwd!()
        }

      [_, skill_name, script_path] ->
        %{skill_name: skill_name, script_path: script_path, args: [], cwd: File.cwd!()}

      _match ->
        %{skill_name: "unknown", script_path: "unknown", args: [], cwd: File.cwd!()}
    end
  end

  defp package_params(text) do
    manager = package_manager(text)
    packages = package_specs(text, manager)

    %{
      manager: manager,
      packages: packages,
      project_root: File.cwd!(),
      save_mode: package_save_mode(text)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)
    |> Map.new()
  end

  defp package_manager(text) do
    normalized = String.downcase(text)

    cond do
      Regex.match?(~r/\bpnpm\b/, normalized) -> "pnpm"
      Regex.match?(~r/\byarn\b/, normalized) -> "yarn"
      Regex.match?(~r/\bpip\b/, normalized) -> "pip"
      true -> "npm"
    end
  end

  defp package_specs(text, manager) do
    text
    |> String.replace(~r/^\s*(run|execute)\s+package\s+install\s+/i, "")
    |> String.replace(~r/^\s*(npm|pnpm|yarn|pip)\s+install\s+/i, "")
    |> String.replace(
      ~r/^\s*(please\s+)?(plan|install|add)\s+(an?\s+)?(#{manager}\s+)?(package|dependency|npm package|pip package)?\s*/i,
      ""
    )
    |> String.replace(~r/\s+to\s+this\s+project.*$/i, "")
    |> String.trim()
    |> split_args()
    |> Enum.reject(&String.starts_with?(&1, "-"))
  end

  defp package_save_mode(text) do
    cond do
      Regex.match?(~r/\b(--save-dev|dev dependency|development dependency)\b/i, text) -> "dev"
      Regex.match?(~r/\b--no-save\b/i, text) -> "no-save"
      true -> nil
    end
  end

  defp online_skill_query(text) do
    text
    |> String.replace(~r/^.*\b(?:search|find)\b\s*/i, "")
    |> String.replace(~r/\bonline\s+skills?\s*(for|about)?\s*/i, "")
    |> String.replace(~r/\bskills\.sh\b/i, "")
    |> String.trim()
    |> case do
      "" -> "allbert"
      query -> query
    end
  end

  defp online_skill_detail_params(text) do
    id =
      case Regex.run(~r/\bonline\s+skill\s+([a-z0-9_.\/:-]+)/i, text) do
        [_, id] -> id
        _match -> "unknown"
      end

    %{source: "skills_sh", id: id}
  end

  defp split_args(""), do: []

  defp split_args(text) do
    OptionParser.split(text)
  rescue
    _exception -> []
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

  defp blank?(value), do: value in [nil, ""]
end
