defmodule AllbertAssist.Pack.Contracts.Settings do
  @moduledoc """
  Residual provider for the kernel `Settings` contract.

  Forwards live. Security Central reads posture on every call, so this adapter
  must not cache or snapshot: an operator settings write has to be visible to
  the next authorization exactly as it is today.
  """

  @behaviour AllbertAssist.Kernel.Contract.Settings

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.{Schema, Secrets, Store, VersionContract}

  @impl true
  defdelegate get(key), to: Settings

  @impl true
  defdelegate defaults(), to: Settings

  @impl true
  defdelegate resolved_settings(), to: Store

  @impl true
  defdelegate get_dotted(settings, key), to: Schema

  @impl true
  defdelegate secret_status(ref), to: Secrets, as: :status

  @impl true
  defdelegate version_contract_status(), to: VersionContract, as: :status_from_store
end
