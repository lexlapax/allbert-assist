defmodule AllbertAssist.Sandbox.Report do
  @moduledoc """
  Typed v0.36 sandbox command report.

  M1 defines the shared shape. Later milestones fill it from bundle, backend,
  command, and gate runner execution.
  """

  defstruct status: :not_started,
            backend: nil,
            command: nil,
            exit_status: nil,
            duration_ms: 0,
            timed_out?: false,
            truncated?: false,
            stdout: "",
            stderr: "",
            report_path: nil,
            diagnostics: [],
            metadata: %{}

  @type t :: %__MODULE__{
          status: :completed | :failed | :denied | :timed_out | :not_started,
          backend: atom() | nil,
          command: map() | nil,
          exit_status: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          timed_out?: boolean(),
          truncated?: boolean(),
          stdout: String.t(),
          stderr: String.t(),
          report_path: String.t() | nil,
          diagnostics: [map()],
          metadata: map()
        }
end
