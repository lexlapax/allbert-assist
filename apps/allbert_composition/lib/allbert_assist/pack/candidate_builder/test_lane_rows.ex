defmodule AllbertAssist.Pack.CandidateBuilder.TestLaneRows do
  @moduledoc """
  Builds canonical Pack-backed gate-owner rows from the shared sealed projection.

  Descriptorless application manifests remain part of the dev-gate projection,
  but only descriptor-bearing Pack applications can contribute callback Rows to
  a Pack Candidate.
  """

  alias AllbertAssist.DevGates.GateOwners
  alias AllbertAssist.Pack.CandidateBuilder.RowFamilies
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.ValidationDiagnostic

  @spec build(Closed.t(), keyword()) ::
          {:ok, RowFamilies.t()} | {:error, [ValidationDiagnostic.t()]}
  def build(closed, opts \\ [])

  def build(%Closed{} = closed, opts) do
    rows = GateOwners.canonical_pack_rows_by_owner!(closed, opts)
    {:ok, %{RowFamilies.empty() | test_lanes: rows}}
  rescue
    _error ->
      {:error,
       [
         %ValidationDiagnostic{
           schema_version: 1,
           code: :invalid_value,
           path: [],
           owner: nil,
           detail: %{reason: :invalid_test_lane_rows}
         }
       ]}
  end

  def build(_closed, _opts) do
    {:error,
     [
       %ValidationDiagnostic{
         schema_version: 1,
         code: :invalid_value,
         path: [],
         owner: nil,
         detail: %{reason: :invalid_test_lane_input}
       }
     ]}
  end
end
