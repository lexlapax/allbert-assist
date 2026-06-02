defmodule AllbertAssist.Marketplace do
  @moduledoc """
  Marketplace Lite facade.

  This is a plain module, not a state-bearing process. v0.45 M1 only reserves
  the public boundary, settings namespace, permission class, operation
  vocabulary, and URI identity. Catalog and install behavior lands in later
  v0.45 milestones.
  """

  @type doctor_result :: %{
          required(:endpoint_kind) => :local_endpoint,
          required(:credential_ok) => nil,
          required(:endpoint_ok) => boolean(),
          required(:model_available) => :unknown,
          required(:context_window) => nil,
          required(:deprecation_warning) => nil,
          required(:last_seen_rate_limit_hint) => nil,
          required(:redacted_host) => String.t(),
          required(:diagnostics) => [map()],
          required(:error_category) => atom(),
          required(:live_check_status) => atom()
        }

  @spec doctor(keyword() | map()) :: {:error, {:not_implemented_yet, doctor_result()}}
  def doctor(_opts \\ []) do
    {:error, {:not_implemented_yet, doctor_stub()}}
  end

  @spec doctor_stub() :: doctor_result()
  def doctor_stub do
    %{
      endpoint_kind: :local_endpoint,
      credential_ok: nil,
      endpoint_ok: false,
      model_available: :unknown,
      context_window: nil,
      deprecation_warning: nil,
      last_seen_rate_limit_hint: nil,
      redacted_host: "local",
      diagnostics: [
        %{
          code: :not_implemented_yet,
          message: "Marketplace doctor is reserved for v0.45 M5."
        }
      ],
      error_category: :unknown_marketplace_doctor_error,
      live_check_status: :not_implemented
    }
  end

  @spec list_entries(keyword() | map()) :: {:error, :not_implemented_yet}
  def list_entries(_opts \\ []), do: {:error, :not_implemented_yet}

  @spec inspect_entry(term(), keyword() | map()) :: {:error, :not_implemented_yet}
  def inspect_entry(_entry_id, _opts \\ []), do: {:error, :not_implemented_yet}

  @spec install_bundle(term(), keyword() | map()) :: {:error, :not_implemented_yet}
  def install_bundle(_entry_id, _opts \\ []), do: {:error, :not_implemented_yet}

  @spec rollback_install(term(), keyword() | map()) :: {:error, :not_implemented_yet}
  def rollback_install(_entry_id, _opts \\ []), do: {:error, :not_implemented_yet}

  @spec list_installed(keyword() | map()) :: {:error, :not_implemented_yet}
  def list_installed(_opts \\ []), do: {:error, :not_implemented_yet}

  @spec verify_bundle_hash(term(), keyword() | map()) :: {:error, :not_implemented_yet}
  def verify_bundle_hash(_entry_id, _opts \\ []), do: {:error, :not_implemented_yet}
end
