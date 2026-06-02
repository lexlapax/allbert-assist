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

  @option_keys %{
    "home" => :home,
    "index_path" => :index_path,
    "installed_state_path" => :installed_state_path,
    "mirror?" => :mirror?,
    "version" => :version
  }

  @spec list_entries(keyword() | map()) :: {:ok, [map()]} | {:error, map()}
  def list_entries(opts \\ []),
    do: AllbertAssist.Marketplace.Catalog.list_entries(normalize_opts(opts))

  @spec inspect_entry(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def inspect_entry(entry_id, opts \\ []) do
    AllbertAssist.Marketplace.Catalog.inspect_entry(to_string(entry_id), normalize_opts(opts))
  end

  @spec install_bundle(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def install_bundle(entry_id, opts \\ []) do
    AllbertAssist.Marketplace.Install.install(to_string(entry_id), normalize_opts(opts))
  end

  @spec rollback_install(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def rollback_install(entry_id, opts \\ []) do
    AllbertAssist.Marketplace.Rollback.rollback(to_string(entry_id), normalize_opts(opts))
  end

  @spec list_installed(keyword() | map()) :: {:ok, [map()]} | {:error, map()}
  def list_installed(opts \\ []),
    do: AllbertAssist.Marketplace.Installed.list(normalize_opts(opts))

  @spec verify_bundle_hash(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def verify_bundle_hash(entry_id, opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, entry} <- AllbertAssist.Marketplace.Catalog.get_entry(to_string(entry_id), opts),
         {:ok, manifest} <-
           AllbertAssist.Marketplace.Bundle.read_and_verify(
             entry,
             AllbertAssist.Marketplace.Catalog.catalog_root(opts),
             opts
           ) do
      {:ok, %{entry: entry, bundle_manifest: manifest, status: :ok}}
    end
  end

  @spec normalize_opts(keyword() | map()) :: keyword()
  def normalize_opts(opts) when is_list(opts), do: opts

  def normalize_opts(opts) when is_map(opts) do
    Enum.flat_map(opts, fn
      {key, value} when is_atom(key) -> [{key, value}]
      {key, value} when is_binary(key) -> maybe_option(key, value)
      _other -> []
    end)
  end

  def normalize_opts(_opts), do: []

  defp maybe_option(key, value) do
    case Map.fetch(@option_keys, key) do
      {:ok, atom_key} -> [{atom_key, value}]
      :error -> []
    end
  end
end
