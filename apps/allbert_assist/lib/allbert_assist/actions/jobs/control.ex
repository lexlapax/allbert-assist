defmodule AllbertAssist.Actions.Jobs.Control do
  @moduledoc """
  Shared authorize → ownership-scope → operate → respond flow for the effectful
  scheduled-job control actions (pause/resume/run). The job is always fetched with the
  ownership-scoped `Jobs.get_job/2` under the server-derived identity, so a control
  action can never touch another user's job (v0.61 M10.4).
  """

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Jobs
  alias AllbertAssist.Security.PermissionGate

  @doc """
  `operation` receives the ownership-scoped `%Job{}` and returns
  `{:ok, message}` on success or `{:error, reason}` on failure.
  """
  @spec run(String.t(), map(), map(), (AllbertAssist.Jobs.Job.t() ->
                                         {:ok, String.t()} | {:error, term()})) ::
          {:ok, map()}
  def run(action_name, params, context, operation) when is_function(operation, 1) do
    permission_decision = PermissionGate.authorize(:job_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(params, context),
         {:ok, id} <- job_id(params),
         {:ok, job} <- Jobs.get_job(user_id, id),
         {:ok, message} <- operation.(job) do
      {:ok,
       %{
         message: message,
         status: :completed,
         permission_decision: permission_decision,
         actions: [
           %{
             name: action_name,
             status: :completed,
             permission: :job_write,
             permission_decision: permission_decision,
             user_id: user_id,
             job_id: id
           }
         ]
       }}
    else
      {:allowed, false} ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             %{
               name: action_name,
               status: :denied,
               permission: :job_write,
               permission_decision: permission_decision
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: control_error_message(reason),
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           actions: [
             %{
               name: action_name,
               status: :error,
               permission: :job_write,
               permission_decision: permission_decision,
               error: reason
             }
           ]
         }}
    end
  end

  defp job_id(params) do
    case Identity.field(params, :id) || Identity.field(params, :job_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_job_id}
    end
  end

  defp control_error_message({:blocked_by_confirmation, confirmation_id}),
    do:
      "Job is blocked by pending confirmation #{confirmation_id}. " <>
        "Inspect it with mix allbert.confirmations show #{confirmation_id}."

  defp control_error_message({:job_not_found, _id}), do: "Job not found for this user."
  defp control_error_message(reason), do: "Job control failed: #{inspect(reason)}"
end
