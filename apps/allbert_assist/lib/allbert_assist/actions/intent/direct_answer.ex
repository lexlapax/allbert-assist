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
      actions: [type: {:list, :map}, required: true]
    ]

  @impl true
  def run(%{text: text}, _context) do
    {:ok,
     %{
       message: message(text),
       status: :completed,
       actions: [
         %{
           name: "direct_answer",
           status: :completed,
           permission: :read_only
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
