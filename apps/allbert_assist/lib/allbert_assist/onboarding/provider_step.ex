defmodule AllbertAssist.Onboarding.ProviderStep do
  @moduledoc """
  v0.63 M3 — the shared provider/model step logic for the guided wizard.

  This module owns the *interpretation* both surfaces (web M5, terminal M6) render:

    * which vault **tier** a new masked credential lands in, and which providers
      already have a key **provided by the environment** (read-only);
    * the **provider-step readiness** — a hosted/BYOK provider chosen with no key
      present is `:needs_credentials` (the one readiness label the model probe never
      emits, per the Readiness Label Mapping Contract);
    * the inline **doctor** round-trip result mapped to operator language (pass/fail
      plus the single repair action).

  It performs no writes and no network itself. Masked credential writes go through
  the `set_provider_credential` action (`:settings_secret_write`); the inline
  round-trip goes through `Settings.ModelDoctor.diagnose/2` / the
  `doctor_model_profile` action; provider switch + custom endpoint reuse
  `set_active_model_profile` and the `providers.*.base_url`/`endpoint_kind` keys.
  Keeping the logic pure + injectable lets it be tested without a keyring or network.
  """

  alias AllbertAssist.Onboarding
  alias AllbertAssist.Settings.Vault

  @typedoc "A vault storage tier."
  @type tier :: :os | :encrypted_file | :env

  @typedoc "Operator-language report of where secrets are stored."
  @type tier_report :: %{
          tier: tier(),
          label: String.t(),
          writable?: boolean(),
          notice: String.t(),
          env_provided: [String.t()]
        }

  @typedoc "The provider-step credential situation for a chosen provider."
  @type credential_status :: %{
          provider: String.t(),
          needs_key?: boolean(),
          key_present?: boolean(),
          source: :vault | :env | :none,
          readiness: Onboarding.readiness()
        }

  @typedoc "Operator-language interpretation of an inline doctor round-trip."
  @type doctor_result :: %{
          ok?: boolean(),
          headline: String.t(),
          detail: String.t(),
          next_action: String.t() | nil
        }

  # ── Vault tier surfacing ───────────────────────────────────────────────────

  @doc """
  Report the active write tier for new masked credentials and the providers that
  already carry an env-provided key (read-only). Reads `Vault.resolve/0` and
  `Vault.Env.env_provided/0` by default; both are injectable for tests.
  """
  @spec vault_tier_report(keyword()) :: tier_report()
  def vault_tier_report(opts \\ []) do
    resolved = Keyword.get_lazy(opts, :resolve, &Vault.resolve/0)
    env_provided = Keyword.get_lazy(opts, :env_provided, &default_env_provided/0)
    tier = resolved.tier

    %{
      tier: tier,
      label: tier_label(tier),
      # New masked entry writes to the active OS/encrypted tier; the env tier is
      # read-only ("provided by environment"), never a write target.
      writable?: tier != :env,
      notice: Map.get(resolved, :notice, ""),
      env_provided: env_provided
    }
  end

  defp default_env_provided do
    Vault.Env.env_provided()
  rescue
    _error -> []
  end

  defp tier_label(:os), do: "OS secret vault (system keychain)"
  defp tier_label(:encrypted_file), do: "encrypted local store"
  defp tier_label(:env), do: "environment (read-only)"

  # ── Provider-step readiness ────────────────────────────────────────────────

  @doc """
  Resolve the credential situation for a chosen provider. A `:local_endpoint`
  provider needs no key. A `:credentialed_remote` provider is `:ready` when a key is
  present (vault or env) and `:needs_credentials` otherwise.

  Inputs (injectable): `:endpoint_kind` (`:local_endpoint | :credentialed_remote`),
  `:key_present?` (bool) and `:key_source` (`:vault | :env | :none`).
  """
  @spec credential_status(String.t(), keyword()) :: credential_status()
  def credential_status(provider, opts \\ []) when is_binary(provider) do
    endpoint_kind = Keyword.get(opts, :endpoint_kind, :credentialed_remote)
    key_present? = Keyword.get(opts, :key_present?, false)
    source = Keyword.get(opts, :key_source, if(key_present?, do: :vault, else: :none))

    needs_key? = endpoint_kind == :credentialed_remote

    readiness =
      cond do
        not needs_key? -> :ready
        key_present? -> :ready
        true -> :needs_credentials
      end

    %{
      provider: provider,
      needs_key?: needs_key?,
      key_present?: key_present?,
      source: if(key_present?, do: source, else: :none),
      readiness: readiness
    }
  end

  # ── Inline doctor interpretation ───────────────────────────────────────────

  @doc """
  Interpret a `Settings.ModelDoctor.diagnose/2` summary (or the `doctor_model_profile`
  action's `:doctor` map) into operator language. Pass requires the endpoint to be
  reachable, the model to be listed, and — for a credentialed remote — the credential
  to check out. Never echoes a host or secret verbatim beyond the doctor's own
  already-redacted `redacted_host`.
  """
  @spec interpret_doctor(map()) :: doctor_result()
  def interpret_doctor(summary) when is_map(summary) do
    endpoint_ok = Map.get(summary, :endpoint_ok, false)
    model_available = Map.get(summary, :model_available, :unknown)
    credential_ok = Map.get(summary, :credential_ok, nil)
    kind = Map.get(summary, :endpoint_kind, :credentialed_remote)

    cond do
      not endpoint_ok ->
        fail("The provider endpoint could not be reached.", "Check the base URL / network.")

      kind == :credentialed_remote and credential_ok == false ->
        fail("The provider rejected the credential.", "Re-enter the provider key.")

      model_available == false ->
        fail(
          "The endpoint is reachable but the model isn't available there.",
          "Pick or pull a listed model."
        )

      model_available == :unknown ->
        %{
          ok?: true,
          headline: "The provider endpoint is reachable.",
          detail: "The model listing was inconclusive; proceeding is fine.",
          next_action: nil
        }

      true ->
        %{
          ok?: true,
          headline: "The provider is verified and the model is available.",
          detail: "Round-trip check passed.",
          next_action: nil
        }
    end
  end

  defp fail(headline, next_action) do
    %{ok?: false, headline: headline, detail: "", next_action: next_action}
  end
end
