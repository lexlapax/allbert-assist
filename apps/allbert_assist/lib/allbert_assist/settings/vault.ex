defmodule AllbertAssist.Settings.Vault do
  @moduledoc """
  Three-tier secret backend (v0.62 M7, signed Locked Decision 12).

  Settings Central keeps holding secret *references*; this module resolves
  where the *values* live, in tier order:

    1. **OS vault** — macOS Keychain (`security`) / Linux Secret Service
       (`secret-tool`), via shell-out (no maintained Elixir library exists).
    2. **Encrypted file** — the existing `Settings.Secrets`
       (`secrets.yml.enc`) as the documented fallback where no vault is
       reachable (headless Linux daemons cannot assume a D-Bus keyring).
    3. **Env injection** — provider keys in the environment (`:req_llm` boot
       read), surfaced in inspection as "env-provided" — never an invisible
       side channel.

  Tier resolution is explicit and surfaced (`resolve/0` returns the active
  tier + why); a vault-absent environment resolves to tier 2 with a notice,
  **never silently**. The active tier is auto-detected but overridable with
  `ALLBERT_VAULT_BACKEND` (`os | encrypted_file | env`).

  This layer is additive: `Settings.Secrets` remains the tier-2 implementation
  and the stable interface; the OS-vault adapters are new.
  """

  alias AllbertAssist.Settings.Secrets

  @type tier :: :os | :encrypted_file | :env
  @type backend :: module()

  @doc "Resolve the active vault tier + a human notice (never silent)."
  @spec resolve() :: %{tier: tier(), backend: backend(), notice: String.t()}
  def resolve do
    case override() do
      {:ok, tier} -> describe(tier, "ALLBERT_VAULT_BACKEND override")
      :none -> auto_resolve()
    end
  end

  @doc "The active backend module."
  def backend, do: resolve().backend

  @doc """
  Store a secret value at its reference through the active tier (v0.63 M8.3).

  Value storage is delegated to the resolved backend; the tier-independent bookkeeping
  (Settings-central api_key_ref, custody invalidation, audit) is applied uniformly so a
  key stored in the OS Keychain is configured in Settings exactly like a tier-2 key. On
  macOS the active tier is `:os`, so this needs no `ALLBERT_SETTINGS_MASTER_KEY`.
  """
  @spec put(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(secret_ref, value, context \\ %{}) do
    %{tier: tier, backend: backend} = resolve()

    with :ok <- Secrets.validate_secret_ref(secret_ref),
         {:ok, stored} <- backend.put(secret_ref, value, context),
         {:ok, diagnostics} <- finalize_bookkeeping(tier, secret_ref, stored, context) do
      {:ok,
       stored
       |> Map.put(:tier, tier)
       |> Map.put(:status, :configured)
       |> Map.put(:diagnostics, diagnostics)}
    end
  end

  @doc """
  Fetch a secret value (or status) through the vault (v0.63 M8.3 + operator-validation F2).

  Reads in tier order: the resolved backend first, then the remaining tiers as fallbacks
  (only on a miss). This makes credential resolution uniform for every consumer — the
  model runtime *and* the doctor — so a key resolves whether it lives in the OS vault, the
  encrypted-file store (upgrade-safe for pre-OS-routing keys), or the environment (the
  documented tier-3 `:req_llm` boot-env source). Without the env fallback, readiness would
  report BYOK-ready from an env key that the doctor then could not read.
  """
  @spec get(String.t(), map()) :: {:ok, term()} | :missing | {:error, term()}
  def get(secret_ref, context \\ %{}) do
    %{tier: tier, backend: backend} = resolve()
    read_through([backend | fallback_backends(tier)], secret_ref, context, :missing)
  end

  defp fallback_backends(:os), do: [__MODULE__.EncryptedFile, __MODULE__.Env]
  defp fallback_backends(:encrypted_file), do: [__MODULE__.Env]
  defp fallback_backends(:env), do: [__MODULE__.EncryptedFile]

  # Try each backend in tier order; a definitive `{:ok, value}` wins immediately. Otherwise
  # keep going so the env tier (last resort) is ALWAYS consulted — a higher tier being
  # unreadable (e.g. tier-2 with no master key in a prod release) must not shadow an
  # env-provided key. If nothing yields a value, surface the first real error (or `:missing`
  # if every tier simply had nothing) so a genuine misconfiguration is still visible.
  defp read_through([], _secret_ref, _context, acc), do: acc

  defp read_through([backend | rest], secret_ref, context, acc) do
    case backend.get(secret_ref, context) do
      {:ok, _value} = ok ->
        ok

      :missing ->
        read_through(rest, secret_ref, context, acc)

      {:error, _reason} = err ->
        read_through(rest, secret_ref, context, keep_first_error(acc, err))
    end
  end

  defp keep_first_error(:missing, err), do: err
  defp keep_first_error(acc, _err), do: acc

  # Tier-2 (EncryptedFile → Secrets.put_secret) already wrote the ref, audited, and
  # invalidated custody; keep its diagnostics. The OS tiers store value-only, so run the
  # shared bookkeeping here.
  defp finalize_bookkeeping(:encrypted_file, _secret_ref, stored, _context),
    do: {:ok, Map.get(stored, :diagnostics, [])}

  defp finalize_bookkeeping(_tier, secret_ref, _stored, context),
    do: Secrets.finalize_external_secret(secret_ref, context)

  @doc "Whether an OS vault backend is reachable on this host."
  @spec os_vault_available?() :: boolean()
  def os_vault_available? do
    case os_backend() do
      :none -> false
      {:ok, mod} -> mod.available?()
    end
  end

  # -- resolution ------------------------------------------------------------

  defp auto_resolve do
    if os_vault_available?() do
      describe(:os, "OS keychain/secret-service reachable")
    else
      describe(
        :encrypted_file,
        "no OS vault reachable — using the encrypted local store (headless-safe fallback)"
      )
    end
  end

  defp override do
    case System.get_env("ALLBERT_VAULT_BACKEND") do
      "os" -> {:ok, :os}
      "encrypted_file" -> {:ok, :encrypted_file}
      "env" -> {:ok, :env}
      _other -> :none
    end
  end

  defp describe(:os, notice) do
    backend =
      case os_backend() do
        :none -> __MODULE__.EncryptedFile
        {:ok, mod} -> mod
      end

    %{tier: :os, backend: backend, notice: notice}
  end

  defp describe(:encrypted_file, notice),
    do: %{tier: :encrypted_file, backend: __MODULE__.EncryptedFile, notice: notice}

  defp describe(:env, notice),
    do: %{tier: :env, backend: __MODULE__.Env, notice: notice}

  defp os_backend do
    case :os.type() do
      {:unix, :darwin} -> {:ok, __MODULE__.MacKeychain}
      {:unix, _linux} -> {:ok, __MODULE__.LinuxSecretService}
      _other -> :none
    end
  end
end
