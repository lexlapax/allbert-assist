defmodule AllbertAssist.Confirmations.Store.Legacy do
  @moduledoc """
  Transitional v0.22 confirmation-store API preserved for v0.23 parity tests.

  This module is deleted during the v0.23 legacy-removal milestone.
  """

  alias AllbertAssist.Confirmations.Store.Persistence

  defdelegate root(), to: Persistence
  defdelegate pending_root(), to: Persistence
  defdelegate resolved_root(), to: Persistence
  defdelegate audit_root(), to: Persistence
  defdelegate ensure_root!(), to: Persistence
  defdelegate create(attrs, opts \\ []), to: Persistence
  defdelegate read(id), to: Persistence
  defdelegate list(opts \\ []), to: Persistence
  defdelegate resolve(id, status, resolution_attrs \\ %{}, opts \\ []), to: Persistence
  defdelegate expire(opts \\ []), to: Persistence
  defdelegate pending_path(id), to: Persistence
  defdelegate resolved_path(id, now \\ DateTime.utc_now()), to: Persistence
  defdelegate audit_path(now \\ DateTime.utc_now()), to: Persistence
end
