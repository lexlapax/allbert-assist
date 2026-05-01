defmodule AllbertAssist.Actions.Intent.DirectAnswer do
  @moduledoc """
  Side-effect-free response action for plain assistant prompts.
  """

  use Jido.Action,
    name: "direct_answer",
    description: "Answer a plain prompt without reading, writing, or executing anything.",
    category: "intent",
    tags: ["intent", "safe", "read_only"],
    schema: [
      text: [type: :string, required: true, doc: "User prompt to answer."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{text: text}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    {:ok,
     %{
       message: message(text),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "direct_answer",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision
         }
       ]
     }}
  end

  defp message(text) do
    """
    I can answer that from the current v0.01 local assistant loop.

    You said: #{text}

    I will keep this turn side-effect-free unless you ask for one of the explicit v0.01 capabilities.
    """
    |> String.trim()
  end
end
