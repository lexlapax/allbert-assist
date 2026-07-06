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
  @spec backend() :: backend()
  def backend, do: resolve().backend

  @doc "Store a secret value at its reference through the active tier."
  @spec put(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(secret_ref, value, context \\ %{}) do
    backend().put(secret_ref, value, context)
  end

  @doc "Fetch a secret value (or status) through the active tier."
  @spec get(String.t(), map()) :: {:ok, term()} | :missing | {:error, term()}
  def get(secret_ref, context \\ %{}) do
    backend().get(secret_ref, context)
  end

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

  @spec os_backend() :: {:ok, module()} | :none
  defp os_backend do
    case :os.type() do
      {:unix, :darwin} -> {:ok, __MODULE__.MacKeychain}
      {:unix, _linux} -> {:ok, __MODULE__.LinuxSecretService}
      _other -> :none
    end
  end
end
