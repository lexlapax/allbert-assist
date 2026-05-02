defmodule AllbertAssist.Actions.Confirmations.ExpireConfirmations do
  @moduledoc false

  use Jido.Action,
    name: "expire_confirmations",
    description: "Expire pending confirmation requests past their TTL.",
    category: "confirmations",
    tags: ["confirmations", "cleanup"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Confirmations.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)

    if PermissionGate.allowed?(permission_decision) do
      {:ok, results} =
        Confirmations.expire(resolution_attrs: Context.resolution_attrs(context, "ttl expired"))

      expired = Enum.flat_map(results, &expired_record/1)

      {:ok,
       %{
         message: "Expired #{length(expired)} confirmation request(s).",
         status: :completed,
         permission_decision: permission_decision,
         confirmations: expired,
         actions: [
           Context.action(
             %{"id" => nil, "status" => "expired"},
             "expire_confirmations",
             :completed,
             permission_decision,
             %{
               count: length(expired)
             }
           )
         ]
       }}
    else
      Context.denied(
        "expire_confirmations",
        :confirmation_decide,
        permission_decision,
        :permission_denied
      )
    end
  end

  defp expired_record({:ok, record}), do: [record]
  defp expired_record(_result), do: []
end
