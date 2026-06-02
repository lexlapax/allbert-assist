defmodule AllbertAssist.Marketplace.Install do
  @moduledoc """
  Marketplace install pipeline for disabled/untrusted v0.45 bundles.
  """

  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Marketplace.Installed

  @spec install(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def install(entry_id, opts \\ []) do
    Installed.with_lock(opts, fn ->
      with {:ok, entry} <- Catalog.get_entry(entry_id, opts),
           :ok <- require_installable(entry),
           {:ok, manifest} <- Bundle.read_and_verify(entry, Catalog.catalog_root(opts), opts),
           {:ok, target} <- resolve_install_target(entry, manifest, opts),
           {:ok, state} <- Installed.read(opts),
           :ok <- reject_conflict(state, entry),
           :ok <- reject_existing_target(target),
           :ok <- copy_bundle(manifest, target),
           {:ok, record} <- build_record(entry, manifest, target),
           :ok <- write_record(state, record, opts) do
        {:ok, %{entry: entry, bundle_manifest: manifest, installed: record}}
      end
    end)
  end

  defp require_installable(%{"kind" => kind}) when kind in ["skill", "template"], do: :ok

  defp require_installable(%{"kind" => "plugin_index"} = entry) do
    {:error,
     Diagnostic.new(
       :plugin_index_not_installable,
       :plugin_index_not_installable,
       "plugin_index entries are browse-only metadata and cannot be installed",
       pointer: "/kind",
       details: %{entry_id: entry["id"]}
     )}
  end

  defp resolve_install_target(entry, manifest, opts) do
    target =
      manifest
      |> Map.fetch!("install_target")
      |> String.replace("<ALLBERT_HOME>", Keyword.get(opts, :home, AllbertAssist.Paths.home()))
      |> Path.expand()

    home = opts |> Keyword.get(:home, AllbertAssist.Paths.home()) |> Path.expand()
    marketplace_root = Path.join(home, "marketplace")
    kind_root = Path.join(marketplace_root, install_dir(entry["kind"]))

    cond do
      not within?(target, marketplace_root) ->
        {:error,
         Diagnostic.new(
           :install_target_invalid,
           :install_target_outside_marketplace,
           "install_target must remain under Allbert Home marketplace",
           pointer: "/install_target",
           details: %{target: target, marketplace_root: marketplace_root}
         )}

      not within?(target, kind_root) ->
        {:error,
         Diagnostic.new(
           :install_target_invalid,
           :install_target_wrong_kind_root,
           "install_target must remain under the per-kind marketplace directory",
           pointer: "/install_target",
           details: %{target: target, kind_root: kind_root}
         )}

      true ->
        {:ok, target}
    end
  end

  defp reject_conflict(%{"installed" => installed}, entry) do
    requested_version = entry["version"]

    installed
    |> Enum.find(&(&1["entry_id"] == entry["id"]))
    |> reject_conflict_for_entry(entry, requested_version)
  end

  defp reject_conflict_for_entry(nil, _entry, _requested_version), do: :ok

  defp reject_conflict_for_entry(%{"version" => version}, entry, requested_version)
       when version == requested_version do
    {:error,
     Diagnostic.new(
       :already_installed,
       :already_installed,
       "marketplace entry version is already installed",
       pointer: "/entry_id",
       details: %{entry_id: entry["id"], version: version}
     )}
  end

  defp reject_conflict_for_entry(%{"version" => version}, entry, requested_version) do
    {:error,
     Diagnostic.new(
       :version_conflict_requires_rollback,
       :version_conflict_requires_rollback,
       "rollback the installed version before installing another version",
       pointer: "/entry_id",
       details: %{
         entry_id: entry["id"],
         installed_version: version,
         requested_version: requested_version
       }
     )}
  end

  defp reject_existing_target(target) do
    if File.exists?(target) do
      {:error,
       Diagnostic.new(
         :install_target_exists,
         :install_target_exists,
         "install target already exists without installed.json ownership",
         pointer: "/install_target",
         details: %{target: target}
       )}
    else
      :ok
    end
  end

  defp copy_bundle(manifest, target) do
    bundle_dir = Map.fetch!(manifest, "bundle_dir")
    File.mkdir_p!(target)

    manifest["files"]
    |> Enum.each(fn %{"path" => relative} ->
      source = Path.join(bundle_dir, relative)
      destination = Path.join(target, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end)

    :ok
  rescue
    exception ->
      File.rm_rf(target)

      {:error,
       Diagnostic.new(
         :install_write_failed,
         :install_write_failed,
         "marketplace bundle files could not be written",
         pointer: "/install_target",
         details: %{target: target, error: Exception.message(exception)}
       )}
  end

  defp build_record(entry, manifest, target) do
    {:ok, installed_at} =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601() |> ok()

    {:ok,
     %{
       "entry_id" => entry["id"],
       "version" => entry["version"],
       "installed_at" => installed_at,
       "install_state" => manifest["install_state"],
       "install_target" => target,
       "bundle_hash" => manifest["bundle_hash"]
     }}
  end

  defp write_record(%{"installed" => installed} = state, record, opts) do
    state
    |> Map.put("installed", installed ++ [record])
    |> Installed.write(opts)
  end

  defp install_dir("skill"), do: "skills"
  defp install_dir("template"), do: "templates"

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp ok(value), do: {:ok, value}
end
