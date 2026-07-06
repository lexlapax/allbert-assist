defmodule AllbertAssist.Settings.Vault.Env do
  @moduledoc """
  Tier-3 vault backend (v0.62 M7): environment-injected provider keys. This is
  the documented home of the `:req_llm` boot-env bypass (the five provider
  keys) — read-only, surfaced in inspection as "env-provided" so it is never an
  invisible side channel. Automation (CI, launchd/systemd EnvironmentFile) uses
  this tier deliberately.
  """
  @behaviour AllbertAssist.Settings.Vault.Backend

  @env_keys ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)

  @impl true
  def available?, do: Enum.any?(@env_keys, &(System.get_env(&1) not in [nil, ""]))

  @impl true
  def put(_secret_ref, _value, _context),
    do: {:error, :env_tier_is_read_only}

  @impl true
  def get(secret_ref, _context) do
    case env_var_for(secret_ref) do
      nil -> :missing
      var -> if val = System.get_env(var), do: {:ok, val}, else: :missing
    end
  end

  @impl true
  def delete(_secret_ref, _context), do: {:error, :env_tier_is_read_only}

  @doc "The provider keys currently env-provided (names only, never values)."
  @spec env_provided() :: [String.t()]
  def env_provided do
    Enum.filter(@env_keys, &(System.get_env(&1) not in [nil, ""]))
  end

  defp env_var_for("secret://providers/anthropic" <> _), do: "ANTHROPIC_API_KEY"
  defp env_var_for("secret://providers/openai" <> _), do: "OPENAI_API_KEY"
  defp env_var_for("secret://providers/openrouter" <> _), do: "OPENROUTER_API_KEY"
  defp env_var_for("secret://providers/google" <> _), do: "GOOGLE_API_KEY"
  defp env_var_for(_other), do: nil
end
