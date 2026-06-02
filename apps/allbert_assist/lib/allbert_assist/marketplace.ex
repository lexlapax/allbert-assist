defmodule AllbertAssist.Marketplace do
  @moduledoc """
  Marketplace Lite facade.

  This is a plain module, not a state-bearing process. Marketplace data lives
  in the shipped catalog and Allbert Home; action modules own the Security
  Central boundary.
  """

  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Marketplace.Doctor
  alias AllbertAssist.Marketplace.Install
  alias AllbertAssist.Marketplace.Installed
  alias AllbertAssist.Marketplace.Rollback

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
          required(:live_check_status) => atom(),
          optional(:checked_at) => String.t(),
          optional(:last_verified_at) => String.t()
        }

  @spec doctor(keyword() | map()) :: {:ok, doctor_result()}
  def doctor(opts \\ []), do: Doctor.run(normalize_opts(opts))

  @option_keys %{
    "expected_schema_version" => :expected_schema_version,
    "home" => :home,
    "index_path" => :index_path,
    "installed_state_path" => :installed_state_path,
    "mirror?" => :mirror?,
    "verbose" => :verbose,
    "version" => :version
  }

  @spec list_entries(keyword() | map()) :: {:ok, [map()]} | {:error, map()}
  def list_entries(opts \\ []), do: Catalog.list_entries(normalize_opts(opts))

  @spec inspect_entry(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def inspect_entry(entry_id, opts \\ []) do
    Catalog.inspect_entry(to_string(entry_id), normalize_opts(opts))
  end

  @spec install_bundle(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def install_bundle(entry_id, opts \\ []) do
    Install.install(to_string(entry_id), normalize_opts(opts))
  end

  @spec rollback_install(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def rollback_install(entry_id, opts \\ []) do
    Rollback.rollback(to_string(entry_id), normalize_opts(opts))
  end

  @spec list_installed(keyword() | map()) :: {:ok, [map()]} | {:error, map()}
  def list_installed(opts \\ []), do: Installed.list(normalize_opts(opts))

  @spec verify_bundle_hash(term(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def verify_bundle_hash(entry_id, opts \\ []) do
    opts = normalize_opts(opts)

    with {:ok, entry} <- Catalog.get_entry(to_string(entry_id), opts),
         {:ok, manifest} <-
           Bundle.read_and_verify(
             entry,
             Catalog.catalog_root(opts),
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
