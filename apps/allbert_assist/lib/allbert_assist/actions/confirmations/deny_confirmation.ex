defmodule AllbertAssist.Actions.Confirmations.DenyConfirmation do
  @moduledoc false

  use Jido.Action,
    name: "deny_confirmation",
    description: "Deny a durable confirmation request without running the target action.",
    category: "confirmations",
    tags: ["confirmations", "denial"],
    schema: [
      id: [type: :string, required: true],
      reason: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Confirmations.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(%{id: id} = params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)
    reason = Map.get(params, :reason)

    cond do
      not PermissionGate.allowed?(permission_decision) ->
        Context.denied(
          "deny_confirmation",
          :confirmation_decide,
          permission_decision,
          :permission_denied
        )

      denial_reason_required?() and blank?(reason) ->
        Context.denied(
          "deny_confirmation",
          :confirmation_decide,
          permission_decision,
          :denial_reason_required
        )

      true ->
        deny(id, reason, context, permission_decision)
    end
  end

  defp deny(id, reason, context, permission_decision) do
    case Confirmations.resolve(id, :denied, Context.resolution_attrs(context, reason)) do
      {:ok, record} ->
        completed(record, permission_decision, idempotent?: false)

      {:error, {:confirmation_not_pending, ^id}} ->
        idempotent(id, permission_decision)

      {:error, reason} ->
        Context.denied("deny_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp idempotent(id, permission_decision) do
    case Confirmations.read(id) do
      {:ok, record} ->
        completed(record, permission_decision, idempotent?: true)

      {:error, reason} ->
        Context.denied("deny_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp completed(record, permission_decision, metadata) do
    {:ok,
     %{
       message: "Confirmation #{record["id"]} is #{record["status"]}.",
       status: :completed,
       permission_decision: permission_decision,
       confirmation: record,
       actions: [
         Context.action(
           record,
           "deny_confirmation",
           :completed,
           permission_decision,
           Map.new(metadata)
         )
       ]
     }}
  end

  defp denial_reason_required? do
    case Settings.get("confirmations.require_reason_for_denial") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
