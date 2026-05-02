defmodule AllbertAssist.Skills.Resource do
  @moduledoc """
  Metadata for a bundled Agent Skill resource.

  v0.03 inventories resource files so operators can inspect what a skill ships,
  but resources are not executed and their contents are not returned by the
  parser.
  """

  @enforce_keys [:path, :kind, :byte_size, :sha256]
  defstruct [:path, :kind, :byte_size, :sha256]

  @type kind :: :script | :reference | :asset

  @type t :: %__MODULE__{
          path: String.t(),
          kind: kind(),
          byte_size: non_neg_integer(),
          sha256: String.t()
        }
end
