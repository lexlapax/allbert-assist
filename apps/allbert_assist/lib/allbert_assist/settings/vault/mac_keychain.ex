defmodule AllbertAssist.Settings.Vault.MacKeychain do
  @moduledoc """
  Tier-1 vault backend for macOS (v0.62 M7): shell-out to `security` (Keychain).
  No maintained Elixir Keychain library exists, so this uses
  `security add-generic-password` / `find-generic-password` /
  `delete-generic-password` under a fixed service name, scoped by the secret
  reference as the account. Secret values are passed as argv `-w` — Keychain
  stores them; they are never logged or echoed. The `runner` is injectable for
  tests.
  """
  @behaviour AllbertAssist.Settings.Vault.Backend

  @service "allbert-assist"

  @impl true
  def available? do
    System.find_executable("security") != nil
  end

  @impl true
  def put(secret_ref, value, _context) do
    case run(["add-generic-password", "-U", "-s", @service, "-a", secret_ref, "-w", value]) do
      {_out, 0} -> {:ok, %{secret_ref: secret_ref, status: :configured, tier: :os}}
      {out, code} -> {:error, {:keychain, code, redact(out)}}
    end
  end

  @impl true
  def get(secret_ref, _context) do
    case run(["find-generic-password", "-s", @service, "-a", secret_ref, "-w"]) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _code} -> :missing
    end
  end

  @impl true
  def delete(secret_ref, _context) do
    case run(["delete-generic-password", "-s", @service, "-a", secret_ref]) do
      {_out, 0} -> {:ok, %{secret_ref: secret_ref, status: :missing}}
      {_out, _code} -> {:ok, %{secret_ref: secret_ref, status: :missing}}
    end
  end

  defp run(args) do
    runner = Application.get_env(:allbert_assist, :vault_security_runner, &default_run/1)
    runner.(args)
  end

  defp default_run(args) do
    System.cmd("security", args, stderr_to_stdout: true)
  rescue
    _error -> {"", 1}
  end

  # Never surface a secret value in an error string.
  defp redact(out), do: String.replace(out, ~r/-w\s+\S+/, "-w [redacted]")
end
