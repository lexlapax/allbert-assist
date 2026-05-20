defmodule AllbertAssist.Confirmations.Store do
  @moduledoc """
  Public confirmation-store facade.

  Since v0.23, lifecycle operations delegate to
  `AllbertAssist.Confirmations.Store.Agent`, a JidoBacked coordinator. Durable
  confirmation YAML and audit markdown still live under Allbert Home and remain
  the authoritative state.
  """

  alias AllbertAssist.Confirmations.Store.Agent
  alias AllbertAssist.Confirmations.Store.Persistence

  defdelegate root(), to: Persistence
  defdelegate pending_root(), to: Persistence
  defdelegate resolved_root(), to: Persistence
  defdelegate audit_root(), to: Persistence
  defdelegate pending_path(id), to: Persistence
  defdelegate resolved_path(id, now \\ DateTime.utc_now()), to: Persistence
  defdelegate audit_path(now \\ DateTime.utc_now()), to: Persistence

  defdelegate ensure_root!(), to: Agent
  defdelegate create(attrs, opts \\ []), to: Agent
  defdelegate read(id), to: Agent
  defdelegate list(opts \\ []), to: Agent
  defdelegate resolve(id, status, resolution_attrs \\ %{}, opts \\ []), to: Agent
  defdelegate annotate_resolution(id, attrs, opts \\ []), to: Agent
  defdelegate expire(opts \\ []), to: Agent
end
