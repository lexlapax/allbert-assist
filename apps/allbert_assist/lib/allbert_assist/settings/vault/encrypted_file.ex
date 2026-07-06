defmodule AllbertAssist.Settings.Vault.EncryptedFile do
  @moduledoc """
  Tier-2 vault backend (v0.62 M7): the existing AES-256-GCM `Settings.Secrets`
  store (`secrets.yml.enc`). This is the documented fallback where no OS vault
  is reachable (headless Linux daemons) — it is `Settings.Secrets` itself, so
  every existing credential flow keeps working unchanged.
  """
  @behaviour AllbertAssist.Settings.Vault.Backend

  alias AllbertAssist.Settings.Secrets

  @impl true
  def available?, do: true

  @impl true
  def put(secret_ref, value, context), do: Secrets.put_secret(secret_ref, value, context)

  @impl true
  def get(secret_ref, context) do
    case Secrets.get_secret(secret_ref, context) do
      {:ok, value} -> {:ok, value}
      :missing -> :missing
      other -> other
    end
  end

  @impl true
  def delete(secret_ref, context), do: Secrets.delete_secret(secret_ref, context)
end
