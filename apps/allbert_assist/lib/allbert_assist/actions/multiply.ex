defmodule AllbertAssist.Actions.Multiply do
  @moduledoc """
  Sample Jido action: multiplies two integers. Wired into `SampleAgent`
  as a tool the LLM can call.
  """
  use Jido.Action,
    name: "multiply",
    description: "Multiply two integers and return the product.",
    schema:
      Zoi.object(%{
        a: Zoi.integer(),
        b: Zoi.integer()
      })

  @impl true
  def run(%{a: a, b: b}, _context) do
    {:ok, %{product: a * b}}
  end
end
