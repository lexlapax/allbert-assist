defmodule AllbertAssist.Actions.SelfImprovement.PromotionAction do
  @moduledoc false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security

  def run(params, context, opts) when is_map(params) and is_map(context) and is_map(opts) do
    permission = Map.fetch!(opts, :permission)
    action_name = Map.fetch!(opts, :action_name)
    kind = Map.fetch!(opts, :kind)
    promote = Map.fetch!(opts, :promote)
    permission_decision = Security.authorize(permission, context)

    with {:allowed, true} <- {:allowed, Security.allowed?(permission_decision)},
         {:ok, id} <- required_id(params) do
      if approval_resume?(context) do
        complete(
          action_name,
          permission,
          permission_decision,
          promote_result(promote, id, params, context)
        )
      else
        create_confirmation(id, kind, action_name, opts, context, permission_decision)
      end
    else
      {:allowed, false} ->
        denied(action_name, permission, permission_decision, :permission_denied)

      {:error, reason} ->
        denied(action_name, permission, permission_decision, reason)
    end
  end

  def run(_params, context, opts) do
    permission = Map.fetch!(opts, :permission)
    action_name = Map.fetch!(opts, :action_name)
    permission_decision = Security.authorize(permission, context)
    denied(action_name, permission, permission_decision, :id_required)
  end

  defp create_confirmation(id, kind, action_name, opts, context, permission_decision) do
    permission = Map.fetch!(opts, :permission)
    execution_mode = Map.fetch!(opts, :execution_mode)
    module = Map.fetch!(opts, :module)

    with {:ok, resume_params} <- resume_params(id, opts),
         {:ok, confirmation} <-
           Confirmations.create(
             %{
               origin: origin(context),
               target_action: %{name: action_name, module: inspect(module)},
               target_permission: permission,
               target_execution_mode: execution_mode,
               security_decision: permission_decision,
               params_summary:
                 Map.merge(%{draft_id: id, kind: kind}, Map.drop(resume_params, [:id])),
               resume_params_ref: resume_params
             },
             context
           ) do
      {:ok,
       %{
         message:
           "Self-improvement #{kind} draft promotion is ready for approval. Confirmation request: #{confirmation["id"]}. No live artifact was written.",
         status: :needs_confirmation,
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation["id"],
         actions: [
           action(action_name, :needs_confirmation, permission, permission_decision, %{
             draft_id: id,
             kind: kind,
             confirmation_id: confirmation["id"],
             execution: :pending_confirmation
           })
         ]
       }}
    else
      {:error, reason} ->
        denied(action_name, permission, permission_decision, reason)
    end
  end

  defp resume_params(id, %{bind_resume_params: binder}) when is_function(binder, 1),
    do: binder.(id)

  defp resume_params(id, _opts), do: {:ok, %{id: id}}

  defp promote_result(promote, id, params, context) when is_function(promote, 3),
    do: promote.(id, params, context)

  defp promote_result(promote, id, _params, context), do: promote.(id, context)

  defp complete(action_name, permission, permission_decision, {:ok, result}) do
    {:ok,
     %{
       message: "Promoted self-improvement draft #{result.draft.id}.",
       status: :completed,
       permission_decision: permission_decision,
       draft: result.draft,
       result: Map.get(result, :result, %{}),
       skill: Map.get(result, :skill),
       workflow: Map.get(result, :workflow),
       memory: Map.get(result, :memory),
       objective: Map.get(result, :objective),
       actions: [
         action(action_name, :completed, permission, permission_decision, %{
           draft_id: result.draft.id,
           kind: result.draft.kind,
           execution: :approval,
           target: Map.get(result, :result, %{})
         })
       ]
     }}
  end

  defp complete(action_name, permission, permission_decision, {:error, reason}) do
    denied(action_name, permission, permission_decision, reason)
  end

  defp denied(action_name, permission, permission_decision, reason) do
    {:ok,
     %{
       message: "Self-improvement draft promotion was denied or unavailable: #{inspect(reason)}",
       status: denied_status(permission_decision, reason),
       permission_decision: permission_decision,
       error: reason,
       actions: [
         action(action_name, :denied, permission, permission_decision, %{
           error: reason,
           execution: :not_started
         })
       ]
     }}
  end

  defp action(action_name, status, permission, permission_decision, metadata) do
    %{
      name: action_name,
      status: status,
      permission: permission,
      permission_decision: permission_decision,
      self_improvement_metadata: metadata
    }
  end

  defp required_id(params) do
    case Map.get(params, :id) || Map.get(params, "id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :id_required}
    end
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp denied_status(permission_decision, :permission_denied),
    do: Response.permission_status(permission_decision)

  defp denied_status(_permission_decision, _reason), do: :denied

  defp origin(context) do
    %{
      channel: Map.get(context, :channel, Map.get(context, "channel", :unknown)),
      actor: Map.get(context, :actor, Map.get(context, "actor", "local")),
      user_id: Map.get(context, :user_id, Map.get(context, "user_id")),
      session_id: Map.get(context, :session_id, Map.get(context, "session_id")),
      surface: Map.get(context, :surface, Map.get(context, "surface", "action"))
    }
  end
end
