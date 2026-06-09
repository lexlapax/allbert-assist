defmodule AllbertAssist.Artifacts.Backfill do
  @moduledoc """
  Backfill retained legacy media roots into Artifacts Central.

  The backfill reads only the retained voice, vision-input, and generated-image
  roots. It never deletes legacy files and intentionally ignores Browser cache
  or other scratch directories.
  """

  alias AllbertAssist.Artifacts.MediaRetention
  alias AllbertAssist.Settings

  @sources [:voice_audio, :vision_media, :generated_image]

  @type summary :: %{
          required(:status) => :completed,
          required(:sources) => [map()],
          required(:candidate_count) => number(),
          required(:ingested_count) => non_neg_integer(),
          required(:unique_sha256_count) => non_neg_integer(),
          required(:artifacts) => [map()]
        }

  @doc "Backfill retained media roots into the artifact store."
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    sources = Keyword.get(opts, :sources, @sources)
    context = Keyword.get(opts, :context, %{})

    with {:ok, source_summaries} <- backfill_sources(sources, context) do
      artifacts = Enum.flat_map(source_summaries, & &1.artifacts)
      sha256s = Enum.map(artifacts, & &1.sha256)

      {:ok,
       %{
         status: :completed,
         sources: source_summaries,
         candidate_count: Enum.sum(Enum.map(source_summaries, & &1.candidate_count)),
         ingested_count: length(artifacts),
         unique_sha256_count: sha256s |> Enum.uniq() |> length(),
         artifacts: artifacts
       }}
    end
  end

  defp backfill_sources(sources, context) do
    Enum.reduce_while(sources, {:ok, []}, fn kind, {:ok, acc} ->
      case backfill_source(kind, context) do
        {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp backfill_source(kind, context) do
    with {:ok, spec} <- MediaRetention.source_spec(kind),
         root <- legacy_root(spec),
         files <- retained_files(root),
         {:ok, artifacts} <- ingest_files(files, root, spec, context) do
      {:ok,
       %{
         kind: spec.kind,
         origin: spec.origin,
         legacy_root_setting: spec.legacy_root_setting,
         root_exists?: File.dir?(root),
         candidate_count: length(files),
         ingested_count: length(artifacts),
         artifacts: artifacts
       }}
    end
  end

  defp ingest_files(files, root, spec, context) do
    Enum.reduce_while(files, {:ok, []}, fn path, {:ok, acc} ->
      case ingest_file(path, root, spec, context) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest_file(path, root, spec, context) do
    relative = Path.relative_to(path, root)

    attrs = %{
      path: path,
      filename: Path.basename(path),
      relative_path_sha256: sha256(relative)
    }

    with {:ok, bytes} <- File.read(path),
         {:ok, artifact} <- MediaRetention.put(spec.kind, bytes, attrs, context: context) do
      {:ok,
       %{
         sha256: artifact.sha256,
         artifact_uri: artifact.artifact_uri,
         byte_size: artifact.byte_size,
         deduped?: artifact.deduped?,
         relative_path_sha256: attrs.relative_path_sha256
       }}
    end
  end

  defp legacy_root(spec) do
    case Settings.get(spec.legacy_root_setting) do
      {:ok, root} when is_binary(root) and root != "" ->
        MediaRetention.expand_home_path(root)

      _other ->
        spec.default_root.()
    end
  end

  defp retained_files(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
    else
      []
    end
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
