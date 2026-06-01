defmodule AllbertAssist.Workflows do
  @moduledoc """
  Facade for v0.44 operator-authored workflow YAML.

  This module is intentionally substrate-only in M1. Workflow files are inert
  data under Allbert Home; M2 adds the loader, validator, and expander that
  lower validated documents into v0.24 objective step attrs. This facade is a
  plain module because it holds no process state and grants no authority.
  """
end
