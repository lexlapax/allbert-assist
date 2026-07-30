defmodule AllbertAssist.Actions.Search.ManageProjection do
  @moduledoc false

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Security.PermissionGate

  @continuation_seconds 5

  def run(operation, action_name, params, context) do
    decision = PermissionGate.authorize(:search_manage, context)

    with true <- PermissionGate.allowed?(decision),
         false <- is_nil(Process.whereis(Projection)),
         {:ok, user_id} <- Identity.user_id(params, context) do
      execute(operation, action_name, user_id, decision)
    else
      false -> denied(action_name, decision)
      true -> failed(action_name, decision, :search_projection_owner_unavailable)
      {:error, reason} -> failed(action_name, decision, reason)
    end
  end

  defp execute(:ingest, action_name, user_id, decision) do
    case Projection.ingest(user_id) do
      {:ok, result} ->
        completed(action_name, decision, result)

      {:error, reason} when reason in [:search_not_ready, :rebuild_required] ->
        schedule_rebuild(action_name, user_id, decision, reason)

      {:error, reason} ->
        failed(action_name, decision, reason)
    end
  end

  defp execute(:maintain, action_name, user_id, decision) do
    case Projection.maintain(user_id) do
      {:ok, result} ->
        completed(action_name, decision, result)

      {:error, reason} when reason in [:search_not_ready, :rebuild_required] ->
        schedule_rebuild(action_name, user_id, decision, reason)

      {:error, reason} ->
        failed(action_name, decision, reason)
    end
  end

  defp execute(:rebuild, action_name, user_id, decision) do
    case Projection.rebuild_step(user_id) do
      {:ok, result} -> completed(action_name, decision, result)
      {:error, reason} -> failed(action_name, decision, reason)
    end
  end

  defp schedule_rebuild(action_name, user_id, decision, reason) do
    case Managed.kick("search-rebuild", user_id) do
      {:ok, kick} ->
        completed(action_name, decision, %{
          status: :complete,
          outcome: :rebuild_scheduled,
          reason: reason,
          rebuild_dirty_seq: kick.dirty_seq
        })

      {:error, kick_error} ->
        failed(action_name, decision, {:rebuild_schedule_failed, kick_error})
    end
  end

  defp completed(action_name, decision, result) do
    response = %{
      message: completion_message(action_name, result),
      status: :completed,
      permission_decision: decision,
      result: result,
      actions: [action(action_name, :completed, decision, result)]
    }

    {:ok, maybe_continue(response, result)}
  end

  defp maybe_continue(response, %{status: :incomplete}) do
    Map.put(
      response,
      :continuation_due_at,
      DateTime.utc_now()
      |> DateTime.add(@continuation_seconds, :second)
      |> DateTime.truncate(:microsecond)
    )
  end

  defp maybe_continue(response, _result), do: response

  defp denied(action_name, decision) do
    {:ok,
     %{
       message: decision.reason,
       status: PermissionGate.response_status(decision),
       permission_decision: decision,
       actions: [action(action_name, :denied, decision, %{})]
     }}
  end

  defp failed(action_name, decision, reason) do
    {:ok,
     %{
       message: "Search projection management failed: #{inspect(reason)}.",
       status: :error,
       error: reason,
       permission_decision: decision,
       actions: [action(action_name, :error, decision, %{error: safe_error(reason)})]
     }}
  end

  defp completion_message(action_name, result) do
    "#{action_name} finished with #{result[:status] || :complete}."
  end

  defp action(action_name, status, decision, result) do
    %{
      name: action_name,
      status: status,
      permission: :search_manage,
      permission_decision: decision,
      result: result
    }
  end

  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error({reason, _detail}) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :search_management_failed
end
