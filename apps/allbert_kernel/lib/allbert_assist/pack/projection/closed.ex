defmodule AllbertAssist.Pack.Projection.Closed do
  @moduledoc """
  Immutable evidence that a sealed Pack projection was reconciled against one
  complete application closure.

  The envelope is consistency evidence for trusted internal composition. It is
  not a Security Central authority token and grants no runtime permission.
  """

  alias AllbertAssist.Pack.Projection.Row

  @enforce_keys [
    :schema_version,
    :closed_applications,
    :pack_applications,
    :rows,
    :projection_sha256,
    :closure_sha256
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          closed_applications: [atom()],
          pack_applications: [atom()],
          rows: [Row.t()],
          projection_sha256: String.t(),
          closure_sha256: String.t()
        }
end
