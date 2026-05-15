defmodule AllbertAssist.Surface.Node do
  @moduledoc """
  Declarative node inside an Allbert surface tree.
  """

  defstruct [
    :id,
    :component,
    props: %{},
    children: [],
    bindings: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          component: atom(),
          props: map(),
          children: [t()],
          bindings: [AllbertAssist.Surface.ActionBinding.t()]
        }
end
