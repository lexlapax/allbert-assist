defmodule AllbertAssist.Portability.Import do
  @moduledoc """
  Dry-run validation for Allbert Home export envelopes.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Portability.Envelope
  alias AllbertAssist.Portability.SecretReferences
  alias AllbertAssist.Settings.VersionContract

  @doc "Read and dry-run validate an export envelope. This never writes to the target Home."
  @spec dry_run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def dry_run(path, opts \\ []) when is_binary(path) do
    target_home = opts |> Keyword.get_lazy(:target_home, &Paths.home/0) |> Path.expand()

    with {:ok, envelope} <- read_envelope(path),
         :ok <- Envelope.validate(envelope) do
      diagnostic = diagnostic(envelope, target_home, path)

      if diagnostic["status"] == "blocked" do
        {:error, diagnostic}
      else
        {:ok, diagnostic}
      end
    else
      {:error, reason} ->
        {:error, error_diagnostic(reason, target_home, path)}
    end
  end

  defp read_envelope(path) do
    with {:ok, content} <- File.read(path),
         {:ok, envelope} <- Jason.decode(content) do
      {:ok, envelope}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp diagnostic(envelope, target_home, source_path) do
    version_report =
      envelope
      |> stored_versions()
      |> then(&VersionContract.status(stored_versions: &1))

    status =
      if version_report.status in [:blocked] do
        "blocked"
      else
        "ok"
      end

    %{
      "status" => status,
      "dry_run" => true,
      "applied" => false,
      "target_home" => target_home,
      "source_envelope" => Path.expand(source_path),
      "envelope_version" => envelope["envelope_version"],
      "settings_version_contract" => version_report,
      "domains" => get_in(envelope, ["manifest", "home", "domains"]) || %{},
      "secret_references" => secret_reference_summary(envelope),
      "inert_import_plan" => %{
        "self_improvement_suggestions" => "inert",
        "voice_capture" => "not_armed",
        "vision_capture" => "not_armed",
        "media_retention" => "metadata_only",
        "applied_changes" => "none"
      },
      "message" => diagnostic_message(status, version_report)
    }
  end

  defp error_diagnostic(reason, target_home, source_path) do
    %{
      "status" => "blocked",
      "dry_run" => true,
      "applied" => false,
      "target_home" => target_home,
      "source_envelope" => Path.expand(source_path),
      "error" => inspect(reason),
      "message" => "Dry-run import blocked before applying changes.",
      "inert_import_plan" => %{
        "self_improvement_suggestions" => "inert",
        "voice_capture" => "not_armed",
        "vision_capture" => "not_armed",
        "applied_changes" => "none"
      }
    }
  end

  defp stored_versions(envelope) do
    envelope
    |> get_in(["settings", "fragments"])
    |> case do
      fragments when is_list(fragments) ->
        Map.new(fragments, fn fragment ->
          {fragment["fragment_id"],
           fragment["known_schema_version"] || fragment["schema_version"]}
        end)

      _other ->
        %{}
    end
  end

  defp secret_reference_summary(envelope) do
    envelope
    |> Map.get("secret_references", [])
    |> SecretReferences.target_summary()
  end

  defp diagnostic_message("ok", version_report) do
    "Dry-run import validated envelope; applied nothing; settings fragments current=#{version_report.counts.current} pending=#{version_report.counts.pending}."
  end

  defp diagnostic_message("blocked", version_report) do
    "Dry-run import refused forward or invalid settings fragment versions; applied nothing; forward=#{version_report.counts.forward} invalid=#{version_report.counts.invalid}."
  end
end
