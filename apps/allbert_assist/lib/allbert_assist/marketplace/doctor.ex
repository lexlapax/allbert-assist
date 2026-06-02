defmodule AllbertAssist.Marketplace.Doctor do
  @moduledoc """
  ADR 0047-style Marketplace Lite doctor.

  The doctor verifies shipped catalog integrity, installed bundle integrity, and
  the preview marketplace schema setting. Output is redacted and persisted as a
  bounded status envelope under Allbert Home.
  """

  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Marketplace.Installed
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @expected_schema_version 1
  @state_path ["marketplace", "doctor", "state.json"]
  @failed_categories MapSet.new([
                       :bundle_hash_mismatch,
                       :bundle_manifest_invalid,
                       :catalog_invalid,
                       :catalog_missing,
                       :catalog_schema_version_unsupported,
                       :installed_state_invalid,
                       :marketplace_schema_version_mismatch,
                       :marketplace_schema_version_unavailable
                     ])

  def run(opts \\ []) do
    checked_at = timestamp()

    expected_schema_version =
      Keyword.get(opts, :expected_schema_version, @expected_schema_version)

    {schema_check, schema_diagnostics} = schema_check(expected_schema_version)
    {catalog_check, catalog_summary, catalog_entries, catalog_diagnostics} = catalog_check(opts)

    {installed_check, installed_summary, installed_diagnostics} =
      installed_check(opts, catalog_entries)

    diagnostics =
      (schema_diagnostics ++ catalog_diagnostics ++ installed_diagnostics)
      |> Enum.map(&redacted_diagnostic/1)

    result =
      checked_at
      |> base_result()
      |> Map.merge(%{
        endpoint_ok: diagnostics == [],
        diagnostics: diagnostics,
        error_category: error_category(diagnostics),
        live_check_status: live_check_status(diagnostics),
        schema_version: schema_setting_value(),
        expected_schema_version: expected_schema_version,
        catalog: catalog_summary,
        installed: installed_summary,
        checks: %{
          schema_version: schema_check,
          catalog: catalog_check,
          catalog_bundles: catalog_bundles_check(catalog_check),
          installed_state: installed_check,
          installed_bundles: installed_bundles_check(installed_check)
        }
      })

    persist(result, opts)

    {:ok, result}
  end

  @spec state_path(keyword()) :: String.t()
  def state_path(opts \\ []) do
    home = Keyword.get(opts, :home, Paths.home())
    Path.join([home | @state_path])
  end

  defp schema_check(expected_schema_version) do
    case Settings.get("marketplace.schema_version") do
      {:ok, ^expected_schema_version} ->
        {:ok, []}

      {:ok, schema_version} ->
        {:failed,
         [
           Diagnostic.new(
             :marketplace_schema_version_mismatch,
             :marketplace_schema_version_mismatch,
             "marketplace.schema_version does not match the running marketplace doctor",
             pointer: "/marketplace/schema_version",
             details: %{
               expected_schema_version: expected_schema_version,
               schema_version: schema_version
             }
           )
         ]}

      {:error, _reason} ->
        {:failed,
         [
           Diagnostic.new(
             :marketplace_schema_version_unavailable,
             :marketplace_schema_version_unavailable,
             "marketplace.schema_version could not be resolved",
             pointer: "/marketplace/schema_version"
           )
         ]}
    end
  end

  defp catalog_check(opts) do
    opts = Keyword.put(opts, :mirror?, false)

    case Catalog.read(opts) do
      {:ok, catalog} ->
        {:ok, catalog_summary(catalog), catalog["entries"], []}

      {:error, diagnostic} ->
        {:failed, catalog_summary(nil), [], [diagnostic]}
    end
  end

  defp installed_check(opts, catalog_entries) do
    case Installed.read(opts) do
      {:ok, %{"installed" => installed}} ->
        diagnostics =
          installed
          |> Enum.with_index()
          |> Enum.flat_map(fn {record, index} -> installed_record_diagnostics(record, index) end)

        check =
          cond do
            diagnostics == [] -> :ok
            Enum.any?(diagnostics, &(&1.error_category == :installed_state_invalid)) -> :failed
            true -> :degraded
          end

        {check, installed_summary(installed, diagnostics, catalog_entries), diagnostics}

      {:error, diagnostic} ->
        {:failed, installed_summary([], [diagnostic], catalog_entries), [diagnostic]}
    end
  end

  defp installed_record_diagnostics(%{"install_target" => target} = record, index)
       when is_binary(target) do
    if File.dir?(target) do
      verify_installed_hash(record, target, index)
    else
      [
        Diagnostic.new(
          :orphan_install,
          :orphan_install,
          "installed marketplace record target is missing",
          pointer: Diagnostic.pointer(["installed", index, "install_target"]),
          details: %{entry_id: record["entry_id"], version: record["version"]}
        )
      ]
    end
  end

  defp installed_record_diagnostics(record, index) do
    [
      Diagnostic.new(
        :installed_state_invalid,
        :installed_record_target_invalid,
        "installed marketplace record target is invalid",
        pointer: Diagnostic.pointer(["installed", index, "install_target"]),
        details: %{entry_id: record["entry_id"], version: record["version"]}
      )
    ]
  end

  defp verify_installed_hash(record, target, index) do
    expected_hash = record["bundle_hash"]

    case Bundle.compute_hash(target) do
      {:ok, ^expected_hash} ->
        []

      {:ok, _hash} ->
        [
          Diagnostic.new(
            :installed_bundle_hash_mismatch,
            :installed_bundle_hash_mismatch,
            "installed marketplace bundle hash does not match installed.json",
            pointer: Diagnostic.pointer(["installed", index, "bundle_hash"]),
            details: %{entry_id: record["entry_id"], version: record["version"]}
          )
        ]

      {:error, diagnostic} ->
        [
          Diagnostic.new(
            :installed_bundle_hash_mismatch,
            :installed_bundle_hash_unavailable,
            "installed marketplace bundle hash could not be computed",
            pointer: Diagnostic.pointer(["installed", index, "bundle_hash"]),
            details: %{
              entry_id: record["entry_id"],
              version: record["version"],
              source_error_category: diagnostic.error_category,
              source_code: diagnostic.code
            }
          )
        ]
    end
  end

  defp catalog_summary(nil) do
    %{
      schema_version: nil,
      catalog_version: nil,
      source: nil,
      entry_count: :unknown
    }
  end

  defp catalog_summary(catalog) do
    %{
      schema_version: catalog["schema_version"],
      catalog_version: catalog["catalog_version"],
      source: catalog["source"],
      entry_count: length(catalog["entries"])
    }
  end

  defp installed_summary(installed, diagnostics, catalog_entries) do
    %{
      count: length(installed),
      checked_count: length(installed) - count_diagnostics(diagnostics, :orphan_install),
      orphan_count: count_diagnostics(diagnostics, :orphan_install),
      tampered_count: count_diagnostics(diagnostics, :installed_bundle_hash_mismatch),
      template_count: Enum.count(installed, &template_install?(&1, catalog_entries))
    }
  end

  defp template_install?(%{"entry_id" => entry_id, "version" => version}, catalog_entries) do
    Enum.any?(catalog_entries, fn entry ->
      entry["id"] == entry_id and entry["version"] == version and entry["kind"] == "template"
    end)
  end

  defp count_diagnostics(diagnostics, category) do
    Enum.count(diagnostics, &(&1.error_category == category))
  end

  defp catalog_bundles_check(:ok), do: :ok
  defp catalog_bundles_check(:failed), do: :unknown

  defp installed_bundles_check(:ok), do: :ok
  defp installed_bundles_check(:degraded), do: :degraded
  defp installed_bundles_check(:failed), do: :failed

  defp base_result(checked_at) do
    %{
      endpoint_kind: :local_endpoint,
      credential_ok: nil,
      endpoint_ok: false,
      model_available: :unknown,
      context_window: nil,
      deprecation_warning: nil,
      last_seen_rate_limit_hint: nil,
      redacted_host: "local",
      checked_at: checked_at,
      last_verified_at: checked_at,
      diagnostics: [],
      error_category: :none,
      live_check_status: :ok
    }
  end

  defp schema_setting_value do
    case Settings.get("marketplace.schema_version") do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp error_category([]), do: :none
  defp error_category([diagnostic | _rest]), do: diagnostic.error_category

  defp live_check_status([]), do: :ok

  defp live_check_status(diagnostics) do
    if Enum.any?(diagnostics, &MapSet.member?(@failed_categories, &1.error_category)) do
      :failed
    else
      :degraded
    end
  end

  defp redacted_diagnostic(%{} = diagnostic) do
    diagnostic
    |> Map.take([:error_category, :code, :message, :pointer, :details])
    |> Map.put_new(:error_category, :unknown_marketplace_doctor_error)
    |> Map.put_new(:code, :marketplace_doctor_failed)
    |> Map.update(:message, "marketplace doctor failed", &bounded_message/1)
    |> maybe_redact_details()
  end

  defp bounded_message(message) when is_binary(message), do: String.slice(message, 0, 256)
  defp bounded_message(message), do: message |> to_string() |> String.slice(0, 256)

  defp maybe_redact_details(%{details: details} = diagnostic) when is_map(details) do
    details =
      details
      |> Map.take([
        :entry_id,
        :version,
        :schema_version,
        :expected_schema_version,
        :source_code,
        :source_error_category
      ])

    if details == %{} do
      Map.delete(diagnostic, :details)
    else
      Map.put(diagnostic, :details, details)
    end
  end

  defp maybe_redact_details(diagnostic), do: diagnostic

  defp persist(result, opts) do
    path = state_path(opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(result, pretty: true)) do
      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
