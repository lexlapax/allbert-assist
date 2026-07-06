defmodule AllbertAssist.Settings.Vault.LinuxSecretService do
  @moduledoc """
  Tier-1 vault backend for Linux (v0.62 M7): shell-out to `secret-tool`
  (libsecret / freedesktop Secret Service). Requires a running D-Bus session +
  keyring daemon — **absent on many headless servers**, where `available?/0`
  returns false and `Vault.resolve/0` falls to the encrypted-file tier with a
  notice (never silent). `runner` is injectable for tests.
  """
  @behaviour AllbertAssist.Settings.Vault.Backend

  @attr "allbert-assist"

  @impl true
  def available? do
    System.find_executable("secret-tool") != nil and
      System.get_env("DBUS_SESSION_BUS_ADDRESS") not in [nil, ""]
  end

  @impl true
  def put(secret_ref, value, _context) do
    # secret-tool store reads the value from stdin.
    case run(["store", "--label", label(secret_ref), "service", @attr, "ref", secret_ref], value) do
      {_out, 0} -> {:ok, %{secret_ref: secret_ref, status: :configured, tier: :os}}
      {out, code} -> {:error, {:secret_tool, code, out}}
    end
  end

  @impl true
  def get(secret_ref, _context) do
    case run(["lookup", "service", @attr, "ref", secret_ref], nil) do
      {out, 0} when out != "" -> {:ok, String.trim(out)}
      _other -> :missing
    end
  end

  @impl true
  def delete(secret_ref, _context) do
    _ = run(["clear", "service", @attr, "ref", secret_ref], nil)
    {:ok, %{secret_ref: secret_ref, status: :missing}}
  end

  defp label(secret_ref), do: "Allbert secret #{secret_ref}"

  defp run(args, stdin) do
    runner = Application.get_env(:allbert_assist, :vault_secret_tool_runner, &default_run/2)
    runner.(args, stdin)
  end

  defp default_run(args, stdin) do
    opts = [stderr_to_stdout: true]
    opts = if stdin, do: Keyword.put(opts, :input, stdin), else: opts
    System.cmd("secret-tool", args, opts)
  rescue
    _error -> {"", 1}
  end
end
