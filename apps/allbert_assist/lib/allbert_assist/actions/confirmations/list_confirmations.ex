defmodule AllbertAssist.Actions.Confirmations.ListConfirmations do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :confirmation_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_confirmations",
    description: "List durable confirmation requests.",
    category: "confirmations",
    tags: ["confirmations", "read_only"],
    schema: [status: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      confirmations: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Confirmations.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    confirmations =
      params
      |> Map.get(:status, "pending")
      |> then(&Confirmations.list(status: &1))
      |> Enum.map(&Confirmations.redact_for_output/1)

    {:ok,
     %{
       message: "Found #{length(confirmations)} confirmation request(s).",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       confirmations: confirmations,
       actions: [
         Context.action(
           %{"id" => nil, "status" => "listed"},
           "list_confirmations",
           :completed,
           %{
             permission_decision
             | permission: :read_only
           },
           %{count: length(confirmations)}
         )
       ]
     }}
  end
end
