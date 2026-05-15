defmodule AllbertAssist.Surface.ActionBinding do
  @moduledoc """
  Declarative binding from a surface affordance to a registered action.
  """

  defstruct [
    :action_name,
    :action_module,
    :app_id,
    :plugin_id,
    :permission,
    :confirmation_required?
  ]

  @type t :: %__MODULE__{
          action_name: String.t(),
          action_module: module() | nil,
          app_id: atom() | nil,
          plugin_id: String.t() | nil,
          permission: atom() | nil,
          confirmation_required?: boolean() | nil
        }
end
