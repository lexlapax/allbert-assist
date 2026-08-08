defmodule AllbertAssist.Kernel.Contract.ResourceRefs do
  @moduledoc """
  Resource-reference derivation for the relocated `External.RequestSpec`.

  `RequestSpec` attaches resource references to an external request summary
  through one call. Closing that edge by relocation would have moved the whole
  Resources value substrate — `Ref`, `ResourceURI`, `OperationClass`, and
  `Scope`, about 1,800 lines of a concern this release did not lock — into the
  kernel to satisfy a single call site. A one-callback port closes it instead
  and leaves the concern where it is.

  Unbound, no references are derived. A summary without them carries less
  detail; it never gains a reference the owner did not produce.
  """

  alias AllbertAssist.Kernel.Contract

  @callback from_external_request_summary(map()) :: [map()]

  @doc "Derive resource references for an external request summary."
  @spec from_external_request_summary(map()) :: [map()]
  def from_external_request_summary(summary) do
    case Contract.fetch(:resource_refs) do
      {:ok, implementation} -> implementation.from_external_request_summary(summary)
      {:error, _unbound} -> []
    end
  end
end
