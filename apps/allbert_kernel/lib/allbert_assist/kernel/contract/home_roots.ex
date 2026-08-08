defmodule AllbertAssist.Kernel.Contract.HomeRoots do
  @moduledoc """
  Component-contributed Home root overrides for the relocated `AllbertAssist.Paths`.

  `Paths` resolves five subsystem roots — settings, memory, artifacts,
  confirmations, and execution audit — through an override its owning component
  may set. Before relocation those overrides were read with the owner's module
  atom as an application-environment key, which is a kernel-names-a-pack
  reference even though no function is called. The owner supplies them here
  instead, keyed by a canonical root id the kernel already knows.

  This is a port and not a value snapshot because the overrides are mutable
  application environment: the suite writes them after boot in roughly twenty
  files, and a generation-bound value would ignore every one of those writes.

  Unbound, there is no override, and `Paths` runs the rest of its precedence
  chain — its own configured key, then `ALLBERT_HOME`, then the default —
  exactly as it does today when no component has set one. When a feature
  extracts into its own pack at M9 its root arrives through the `home_roots/0`
  descriptor contribution; this port covers the residual, which owns no
  descriptor of its own.
  """

  alias AllbertAssist.Kernel.Contract

  @root_ids [:settings, :memory, :artifacts, :confirmations, :execution_audit]

  @typedoc "A canonical Home root an owner may override."
  @type root_id :: :settings | :memory | :artifacts | :confirmations | :execution_audit

  @callback override(atom()) :: Path.t() | nil

  @doc "The canonical root ids `Paths` may ask an owner about."
  @spec root_ids() :: [root_id()]
  def root_ids, do: Enum.sort(@root_ids)

  @doc """
  The owner-contributed override for one canonical root, or nil.

  An id outside the closed list is refused rather than forwarded, so a caller
  cannot use this contract to read arbitrary owner configuration.
  """
  @spec override(atom()) :: Path.t() | nil
  def override(root_id) when root_id in @root_ids do
    case Contract.fetch(:home_roots) do
      {:ok, implementation} -> implementation.override(root_id)
      {:error, _unbound} -> nil
    end
  end

  def override(_root_id), do: nil
end
