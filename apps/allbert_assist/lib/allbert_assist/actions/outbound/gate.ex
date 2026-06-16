defmodule AllbertAssist.Actions.Outbound.Gate do
  @moduledoc """
  v0.54 M10 (ADR 0063) — shared confirmation/resume flow for outbound compose
  actions (`send_email`, `send_channel_message`, `create_calendar_event`).

  `run/3` authorizes the action's permission and:

    * `:denied` → a stopped response (never sends);
    * allowed **or** an approved resume → runs the caller's `send_fn` and wraps the
      result (`:completed` / `:failed`);
    * `:needs_confirmation` → creates a `Confirmations` record (with the caller's
      `resume_params` so the **opt-in generic resume** re-runs it on approval) and
      returns a `:needs_confirmation` response — the router/runtime renders the
      approve/deny primitive.

  Routing grants no authority; this gate is the only execution boundary. Secrets
  must already be redacted out of `summary` by the caller.
  """
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Security.PermissionGate

  @type spec :: %{
          required(:action_name) => String.t(),
          required(:permission) => atom(),
          required(:execution_mode) => atom(),
          required(:summary) => map(),
          required(:resume_params) => map()
        }

  @spec run(spec(), map(), (-> {:ok, map()} | {:error, term()})) :: {:ok, map()}
  def run(spec, context, send_fn) when is_function(send_fn, 0) do
    decision = PermissionGate.authorize(spec.permission, context)

    cond do
      decision.decision == :denied ->
        {:ok, stopped(spec, decision, :permission_denied)}

      PermissionGate.allowed?(decision) or approved_resume?(context) ->
        execute(spec, decision, send_fn)

      decision.decision == :needs_confirmation ->
        needs_confirmation(spec, context, decision)

      true ->
        {:ok, stopped(spec, decision, :permission_denied)}
    end
  end

  defp execute(spec, decision, send_fn) do
    case send_fn.() do
      {:ok, receipt} ->
        {:ok,
         %{
           message: "#{humanize(spec.action_name)} completed.",
           status: :completed,
           permission_decision: decision,
           receipt: receipt,
           actions: [action(spec, :completed, decision, %{receipt: receipt})]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "#{humanize(spec.action_name)} failed: #{inspect(reason)}.",
           status: :failed,
           error: reason,
           permission_decision: decision,
           actions: [action(spec, :failed, decision, %{error: inspect(reason)})]
         }}
    end
  end

  defp needs_confirmation(spec, context, decision) do
    attrs = %{
      origin: Origin.from_context(context, spec.action_name),
      target_action: %{name: spec.action_name, module: nil},
      target_permission: spec.permission,
      target_execution_mode: spec.execution_mode,
      security_decision: decision,
      source_signal_id: field(context, :input_signal_id) || field(context, :source_signal_id),
      source_trace_id: field(context, :trace_id) || field(context, :source_trace_id),
      runner_metadata: runner_metadata(context, spec.action_name),
      params_summary: spec.summary,
      resume_params_ref: spec.resume_params
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        id = confirmation_id(confirmation)

        {:ok,
         %{
           message: "#{humanize(spec.action_name)} needs confirmation.",
           status: :needs_confirmation,
           error: :permission_denied,
           permission_decision: decision,
           confirmation: Confirmations.redact_for_output(confirmation),
           confirmation_id: id,
           actions: [
             action(spec, :needs_confirmation, decision, %{confirmation_id: id})
           ]
         }}

      {:error, reason} ->
        {:ok, stopped(spec, decision, {:confirmation_create_failed, reason})}
    end
  end

  defp stopped(spec, decision, reason) do
    %{
      message: "#{humanize(spec.action_name)} was not run (#{inspect(reason)}).",
      status: :stopped,
      error: reason,
      permission_decision: decision,
      actions: [action(spec, :stopped, decision, %{reason: inspect(reason)})]
    }
  end

  defp action(spec, status, decision, metadata) do
    %{
      name: spec.action_name,
      status: status,
      permission: spec.permission,
      permission_decision: decision,
      summary: spec.summary,
      metadata: metadata
    }
  end

  defp runner_metadata(context, action_name) do
    context
    |> Map.take([:actor, :user_id, :operator_id, :channel, :surface, :response_target])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:selected_action, action_name)
  end

  defp approved_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approved_resume?(_context), do: false

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(%{id: id}), do: id

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp field(_map, _key), do: nil

  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()
end
