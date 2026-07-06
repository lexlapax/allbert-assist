defmodule AllbertAssist.CLI.Areas.Objectives do
  @moduledoc """
  Release-safe `objectives` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.objectives`, `mix allbert.delegate`
  and `allbert admin objectives`: `dispatch/2` parses the sub-argv, routes to the
  same registered actions the Mix tasks used
  (`list`/`show`/`continue`/`cancel_objective` and `delegate_agent`), and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release.

  This area is the union of the old `allbert.objectives` and `allbert.delegate`
  tasks: `list`/`show`/`continue`/`cancel` map to objective inspection, while any
  other leading token is treated as a delegate AGENT_ID. Both thin Mix wrappers
  (`Mix.Tasks.Allbert.Objectives`, `Mix.Tasks.Allbert.Delegate`) print the output
  through `Mix.shell/0` and preserve the documented sysexits-style exit codes
  (64 usage, 65 not-found, 66 identity, 1 failure) via their own `halt/1`.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage_exit 64
  @not_found_exit 65
  @identity_exit 66
  @failure_exit 1
  @stored_summary_limit 2_000

  @usage """
  Usage:
    allbert admin objectives list [--user USER] [--status open|running|blocked|completed|cancelled|failed|abandoned] [--active-app APP_ID] [--limit N]
    allbert admin objectives show OBJECTIVE_ID [--user USER]
    allbert admin objectives continue OBJECTIVE_ID [--user USER]
    allbert admin objectives cancel OBJECTIVE_ID --reason REASON [--user USER]
    allbert admin objectives AGENT_ID '{"key":"value"}' [--user USER] [--command execute]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    base = context || default_context()

    try do
      argv
      |> route(base)
      |> render()
    catch
      {:area_error, code, message} -> {message, code}
    end
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin objectives")

  defp route(["list" | args], base) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          user: :string,
          operator: :string,
          status: :string,
          active_app: :string,
          limit: :integer
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "list")
    user_id = user_id!(opts)

    params =
      %{
        user_id: user_id,
        status: opts[:status],
        active_app: opts[:active_app],
        limit: opts[:limit]
      }
      |> drop_nil()

    with {:ok, response} <-
           completed_action("list_objectives", params, context_for(base, user_id)) do
      {:ok, {:list, response.objectives}}
    end
  end

  defp route(["show", id | args], base) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "show")
    user_id = user_id!(opts)

    with {:ok, response} <-
           accepted_action(
             "show_objective",
             %{id: id, user_id: user_id},
             context_for(base, user_id)
           ) do
      {:ok, {:show, response}}
    end
  end

  defp route(["continue", id | args], base) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string, operator: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "continue")
    user_id = user_id!(opts)

    case Runner.run(
           "continue_objective",
           %{id: id, user_id: user_id},
           context_for(base, user_id)
         ) do
      {:ok, %{status: status} = response}
      when status in [
             :completed,
             :needs_confirmation,
             :still_blocked,
             :objective_abandoned,
             :objective_cancelled,
             :objective_failed
           ] ->
        {:ok, {:continue, response}}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp route(["cancel", id | args], base) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          user: :string,
          operator: :string,
          reason: :string
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest, "cancel")
    user_id = user_id!(opts)
    reason = required_reason!(opts)

    case Runner.run(
           "cancel_objective",
           %{id: id, user_id: user_id, reason: reason},
           context_for(base, user_id)
         ) do
      {:ok, %{status: :cancelled} = response} ->
        {:ok, {:cancel, response}}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp route([], _base), do: {:usage, @usage}

  defp route([agent_id | rest], base) when is_binary(agent_id) do
    delegate(agent_id, rest, base)
  end

  # --- Delegate subcommand (from the retired `mix allbert.delegate`) ----------

  defp delegate(agent_id, rest, base) do
    {opts, positional, invalid} =
      OptionParser.parse(rest,
        strict: [user: :string, operator: :string, command: :string, params: :string]
      )

    reject_invalid!(invalid)
    user_id = user_id!(opts)
    params = params!(opts, positional)

    with {:ok, entry} <- lookup_agent(agent_id),
         {:ok, objective} <- create_debug_objective(user_id, entry, params),
         {:ok, step} <- create_debug_step(objective, entry, params),
         {:ok, response} <-
           Runner.run(
             "delegate_agent",
             %{
               user_id: user_id,
               objective_id: objective.id,
               step_id: step.id,
               delegate_agent_id: entry.id,
               command: Keyword.get(opts, :command, "execute"),
               params: params
             },
             delegate_context(base, user_id, entry)
           ) do
      finish_debug_objective(objective, step, response)
      {:ok, {:delegate, entry, objective, response}}
    else
      {:error, :not_found} ->
        fail!(@not_found_exit, "Agent #{agent_id} not found in AgentRegistry.")

      {:error, reason} ->
        fail!(@failure_exit, "Delegate command failed: #{inspect(reason)}")
    end
  end

  # --- Rendering --------------------------------------------------------------

  defp render({:ok, {:list, []}}), do: Render.ok("No objectives.")

  defp render({:ok, {:list, objectives}}) do
    Render.ok(Enum.map(objectives, &objective_list_line/1))
  end

  defp render({:ok, {:show, %{status: :not_found}}}) do
    {"Objective not found.", @not_found_exit}
  end

  defp render({:ok, {:show, response}}), do: Render.ok(show_lines(response))
  defp render({:ok, {:continue, response}}), do: Render.ok(continue_lines(response))
  defp render({:ok, {:cancel, response}}), do: Render.ok(cancel_lines(response))

  defp render({:ok, {:delegate, entry, objective, response}}) do
    Render.ok(delegate_lines(entry, objective, response))
  end

  defp render({:usage, usage}), do: {String.trim_trailing(usage), @usage_exit}

  defp render({:error, reason}) do
    {"Objectives command failed: #{inspect(reason)}", error_code(reason)}
  end

  defp objective_list_line(objective) do
    "#{objective.id} #{objective.status} app=#{objective.active_app || "none"} #{objective.title}"
  end

  defp show_lines(response) do
    objective = response.objective

    [
      "Objective: #{objective.id}",
      "Title: #{objective.title}",
      "Status: #{objective.status}",
      "User: #{objective.user_id}"
    ] ++
      field_line("Active app", objective[:active_app]) ++
      field_line("Thread", objective[:source_thread_id]) ++
      ["", objective.objective, "", "Steps:"] ++
      step_lines(response.steps) ++
      ["", "Events:"] ++
      event_lines(response.events)
  end

  defp continue_lines(response) do
    [response.message] ++
      optional_line("Confirmation", Map.get(response, :confirmation_id)) ++
      optional_line("Reason", Map.get(response, :reason))
  end

  defp cancel_lines(response) do
    [response.message] ++
      optional_line("Cancelled steps", Map.get(response, :cancelled_step_count))
  end

  defp delegate_lines(entry, objective, response) do
    [
      "Allbert delegate #{entry.id}",
      "Status: #{response.status}",
      "Objective: #{objective.id}"
    ] ++ delegate_result_lines(response)
  end

  defp delegate_result_lines(response) do
    state = get_in(response, [:delegate_result, :state]) || %{}

    case Map.get(state, :last_result) || Map.get(state, "last_result") do
      {:ok, report} ->
        ["Summary: #{summary(report)}", "Report: #{bounded(report)}"]

      {:error, reason} ->
        ["Error: #{inspect(reason)}"]

      _other ->
        ["Result: #{bounded(response.delegate_result)}"]
    end
  end

  defp step_lines([]), do: ["- none"]

  defp step_lines(steps) do
    Enum.map(steps, fn step ->
      "- #{step.id} #{step.status} #{step.kind} stage=#{step.stage} action=#{step[:candidate_action] || "none"}"
    end)
  end

  defp event_lines([]), do: ["- none"]

  defp event_lines(events) do
    Enum.map(events, fn event ->
      "- #{event.kind} #{event.summary || ""}"
    end)
  end

  defp field_line(_label, nil), do: []
  defp field_line(label, value), do: ["#{label}: #{value}"]

  defp optional_line(_label, nil), do: []
  defp optional_line(label, value), do: ["#{label}: #{value}"]

  # --- Actions / context ------------------------------------------------------

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp accepted_action(action_name, params, ctx) do
    case Runner.run(action_name, params, ctx) do
      {:ok, %{status: status} = response} when status in [:completed, :not_found] ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp context_for(base, user_id) do
    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: Map.get(base, :surface, "allbert admin objectives")
    )
  end

  defp delegate_context(base, user_id, entry) do
    app_id = entry.metadata[:app_id] || entry.metadata["app_id"]

    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      surface: Map.get(base, :surface, "allbert admin objectives"),
      app_id: app_id
    )
  end

  # --- Delegate helpers -------------------------------------------------------

  defp lookup_agent(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp create_debug_objective(user_id, entry, params) do
    app_id = entry.metadata[:app_id] || entry.metadata["app_id"]

    Objectives.create_objective(%{
      user_id: user_id,
      title: "debug.delegate.#{entry.id}",
      objective: "Delegate #{entry.id} with #{inspect(Map.keys(params))}.",
      active_app: if(is_atom(app_id), do: Atom.to_string(app_id), else: app_id),
      status: "open",
      source_intent: "mix allbert.delegate"
    })
  end

  defp create_debug_step(objective, entry, params) do
    Objectives.create_step(%{
      objective_id: objective.id,
      kind: "delegate_agent",
      status: "selected",
      stage: "execute_step",
      delegate_agent_id: entry.id,
      action_params: params
    })
  end

  defp finish_debug_objective(objective, step, %{status: :completed} = response) do
    summary = stored_summary(response.message)

    {:ok, _step} =
      Objectives.update_step(step, %{
        status: "completed",
        stage: "observe_step",
        result_summary: summary
      })

    {:ok, _objective} =
      Objectives.update_objective(objective, %{
        status: "completed",
        progress_summary: summary,
        completed_at: DateTime.utc_now()
      })

    :ok
  end

  defp finish_debug_objective(objective, step, response) do
    summary = stored_summary(response)

    {:ok, _step} =
      Objectives.update_step(step, %{status: "failed", result_summary: summary})

    {:ok, _objective} =
      Objectives.update_objective(objective, %{
        status: "failed",
        progress_summary: summary
      })

    :ok
  end

  defp params!(opts, positional) do
    params_source =
      Keyword.get(opts, :params) ||
        case positional do
          [] -> "{}"
          [json] -> json
          rest -> fail!(@usage_exit, "Unexpected delegate arguments: #{inspect(rest)}")
        end

    case Jason.decode(params_source) do
      {:ok, %{} = params} -> params
      {:ok, _other} -> fail!(@usage_exit, "Delegate params must decode to a JSON object.")
      {:error, reason} -> fail!(@usage_exit, "Invalid delegate params JSON: #{inspect(reason)}")
    end
  end

  defp summary(%{} = report) do
    Map.get(report, :summary) || Map.get(report, "summary") ||
      inspect(Map.take(report, [:status]))
  end

  defp summary(report), do: inspect(report)

  defp bounded(value) do
    text = inspect(value, limit: 20, printable_limit: 1_200)
    if byte_size(text) > 1_200, do: binary_part(text, 0, 1_200), else: text
  end

  defp stored_summary(value) when is_binary(value) do
    if String.length(value) > @stored_summary_limit,
      do: String.slice(value, 0, @stored_summary_limit),
      else: value
  end

  defp stored_summary(value), do: bounded(value)

  # --- Identity / option validation -------------------------------------------

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        fail!(@identity_exit, "--user and --operator must match when both are provided.")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp required_reason!(opts) do
    opts[:reason]
    |> blank_to_nil()
    |> case do
      nil -> fail!(@usage_exit, "Usage error (64): cancel requires --reason REASON.")
      reason -> reason
    end
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Unknown options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: fail!(@usage_exit, "Unexpected #{command} arguments: #{inspect(rest)}")

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp error_code(:not_found), do: @not_found_exit
  defp error_code({:not_found, _id}), do: @not_found_exit
  defp error_code(:missing_reason), do: @usage_exit
  defp error_code(:missing_objective_id), do: @usage_exit
  defp error_code(:missing_user_id), do: @usage_exit
  defp error_code(_reason), do: @failure_exit

  @spec fail!(non_neg_integer(), String.t()) :: no_return()
  defp fail!(code, message), do: throw({:area_error, code, message})
end
