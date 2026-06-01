defmodule AllbertAssist.Workflows.SchemaError do
  @moduledoc """
  Structured validation error for operator workflow YAML.

  Values are redacted or summarized before entering this struct; callers should
  use `pointer` and `reason` for programmatic diagnostics.
  """

  defexception [
    :pointer,
    :reason,
    :expected,
    :got,
    :workflow_id,
    :redacted_value,
    message: "invalid workflow"
  ]

  @type t :: %__MODULE__{
          pointer: String.t(),
          reason: atom(),
          expected: term(),
          got: term(),
          workflow_id: String.t() | nil,
          redacted_value: term(),
          message: String.t()
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    reason = Map.get(attrs, :reason, :invalid_workflow)
    pointer = Map.get(attrs, :pointer, "/")

    %__MODULE__{
      pointer: pointer,
      reason: reason,
      expected: Map.get(attrs, :expected),
      got: Map.get(attrs, :got),
      workflow_id: Map.get(attrs, :workflow_id),
      redacted_value: Map.get(attrs, :redacted_value),
      message: Map.get(attrs, :message) || "#{reason} at #{pointer}"
    }
  end
end
