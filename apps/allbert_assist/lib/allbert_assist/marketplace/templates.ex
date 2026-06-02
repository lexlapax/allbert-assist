defmodule AllbertAssist.Marketplace.Templates do
  @moduledoc """
  Metadata-only view of installed marketplace template bundles.

  Marketplace template metadata is informational input for `workspace:create`.
  It does not extend the executable v0.38 template registry and does not grant
  live integration authority.
  """

  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Marketplace.Installed

  @metadata_file "metadata.json"

  @spec list_installed(keyword()) :: {:ok, [map()]} | {:error, map()}
  def list_installed(opts \\ []) do
    with {:ok, entries} <- Catalog.list_entries(Keyword.put(opts, :mirror?, false)),
         {:ok, installed} <- Installed.list(opts) do
      templates =
        installed
        |> Enum.flat_map(&template_record(&1, entries))
        |> Enum.sort_by(& &1.entry_id)

      {:ok, templates}
    end
  end

  defp template_record(record, entries) do
    case catalog_template(record, entries) do
      nil ->
        []

      entry ->
        case read_template(record, entry) do
          {:ok, template} -> [template]
          {:error, _diagnostic} -> []
        end
    end
  end

  defp catalog_template(%{"entry_id" => entry_id, "version" => version}, entries) do
    Enum.find(entries, fn entry ->
      entry["id"] == entry_id and entry["version"] == version and entry["kind"] == "template"
    end)
  end

  defp read_template(%{"install_target" => target} = record, entry) do
    with {:ok, metadata} <- read_metadata(target),
         :ok <- validate_metadata(metadata),
         {:ok, files} <- Bundle.content_files(target) do
      {:ok,
       %{
         entry_id: record["entry_id"],
         version: record["version"],
         install_state: record["install_state"],
         bundle_hash: record["bundle_hash"],
         name: metadata["name"],
         description: metadata["description"],
         pattern_id: metadata["pattern_id"],
         authority: metadata["authority"],
         live_integration?: metadata["live_integration"] == true,
         parameters: normalize_parameters(metadata["parameters"]),
         files: Enum.map(files, &%{path: &1.path, sha256: &1.sha256}),
         catalog_entry: entry
       }}
    end
  end

  defp read_metadata(target) do
    path = Path.join(target, @metadata_file)

    with true <- File.regular?(path) || {:error, diagnostic(:missing_metadata)},
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) || {:error, diagnostic(:metadata_not_object)} do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         diagnostic(:metadata_invalid_json, details: %{message: Exception.message(error)})}

      {:error, %{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error, diagnostic(:metadata_read_failed, details: %{reason: inspect(reason)})}
    end
  end

  defp validate_metadata(%{
         "schema_version" => 1,
         "pattern_id" => pattern_id,
         "name" => name,
         "description" => description,
         "parameters" => parameters,
         "live_integration" => false,
         "authority" => "metadata_only"
       })
       when is_binary(pattern_id) and is_binary(name) and is_binary(description) and
              is_list(parameters) do
    if Enum.all?(parameters, &valid_parameter?/1) do
      :ok
    else
      {:error, diagnostic(:metadata_invalid_parameters)}
    end
  end

  defp validate_metadata(%{"schema_version" => version}) when version != 1,
    do: {:error, diagnostic(:metadata_schema_unsupported)}

  defp validate_metadata(_metadata), do: {:error, diagnostic(:metadata_invalid)}

  defp valid_parameter?(%{"name" => name, "type" => type})
       when is_binary(name) and is_binary(type),
       do: true

  defp valid_parameter?(_parameter), do: false

  defp normalize_parameters(parameters) do
    Enum.map(parameters, fn parameter ->
      %{
        name: parameter["name"],
        type: parameter["type"],
        required?: Map.get(parameter, "required", false) == true
      }
    end)
  end

  defp diagnostic(code, opts \\ []) do
    Diagnostic.new(:template_metadata_invalid, code, message(code), opts)
  end

  defp message(:missing_metadata), do: "marketplace template metadata.json is missing"
  defp message(:metadata_invalid_json), do: "marketplace template metadata JSON is invalid"
  defp message(:metadata_not_object), do: "marketplace template metadata must be an object"
  defp message(:metadata_read_failed), do: "marketplace template metadata could not be read"

  defp message(:metadata_schema_unsupported),
    do: "marketplace template schema_version is unsupported"

  defp message(:metadata_invalid_parameters), do: "marketplace template parameters are invalid"
  defp message(:metadata_invalid), do: "marketplace template metadata is invalid"
end
