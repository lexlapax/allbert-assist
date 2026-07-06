defmodule AllbertAssist.Actions.Support.ConfirmationRequest do
  @moduledoc """
  v0.62 M8.14: turn a permission `:needs_confirmation` into a durable
  `Confirmations` record so `allbert admin confirmations approve <id>` (and every
  other approval surface) can complete the action.

  Effectful actions with a `:needs_confirmation` safety floor (install_ollama,
  pull_model, service_control) previously returned the status but never persisted
  a record, so they were non-completable. Call `resolve/3` in the
  needs-confirmation branch to create the record; the action name must be in
  `ApproveConfirmation`'s resume dispatch so approval re-runs it with the
  server-set `confirmation.approved?` context.
  """

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate

  @doc """
  Given a permission decision and the target-action attrs, either persist a
  confirmation record (`{:needs_confirmation, confirmation}`), report `:denied`,
  or `:allowed` (floor did not apply). `attrs` must carry `:target_action`,
  `:target_permission`, `:target_execution_mode`, `:params_summary`, and
  `:resume_params_ref`.
  """
  @spec resolve(map(), map(), map()) ::
          {:needs_confirmation, map()} | :denied | :allowed
  def resolve(permission_decision, attrs, context) do
    case PermissionGate.response_status(permission_decision) do
      :needs_confirmation ->
        {:ok, confirmation} =
          Confirmations.create(
            Map.merge(
              %{origin: origin(context), security_decision: permission_decision},
              attrs
            )
          )

        {:needs_confirmation, confirmation}

      :denied ->
        :denied

      _completed ->
        :allowed
    end
  end

  defp origin(context) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor) || get_in(context, [:request, :operator_id]) || "local",
      surface: Map.get(context, :surface, "action")
    }
  end
end
