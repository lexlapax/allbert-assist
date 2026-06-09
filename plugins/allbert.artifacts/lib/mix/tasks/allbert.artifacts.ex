defmodule Mix.Tasks.Allbert.Artifacts do
  @moduledoc """
  Artifacts Browser operator helpers.
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Runtime.Redactor

  @shortdoc "Browse Artifacts Central metadata"

  @impl true
  def run(["list" | rest]) do
    Mix.Task.run("app.start")

    with {:ok, params} <- list_params(rest),
         {:ok, %{status: :completed, artifacts: artifacts}} <-
           Runner.run("list_artifacts", params, cli_context()) do
      if artifacts == [] do
        Mix.shell().info("artifacts: none")
      else
        Enum.each(artifacts, &print_artifact_row/1)
      end
    else
      {:error, message} ->
        Mix.shell().error("artifacts list failed: #{message}")

      {:ok, response} ->
        print_action_error("artifacts list failed", response)
    end
  end

  def run(["show", artifact_ref | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("get_artifact", get_params(artifact_ref), cli_context()) do
      {:ok, %{status: :completed, artifact: artifact}} ->
        print_artifact_detail(artifact)

      {:ok, response} ->
        print_action_error("artifacts show failed", response)
    end
  end

  def run(["threads", artifact_ref | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("artifact_threads", artifact_ref_params(artifact_ref), cli_context()) do
      {:ok, %{status: :completed, links: []}} ->
        Mix.shell().info("artifact threads: none")

      {:ok, %{status: :completed, links: links}} ->
        Enum.each(links, &print_thread_link/1)

      {:ok, response} ->
        print_action_error("artifact threads failed", response)
    end
  end

  def run(["doctor" | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("artifact_doctor", %{}, cli_context()) do
      {:ok, %{status: :completed, doctor: doctor}} ->
        gc_last_check = raw_map_value(doctor, :gc_last_check, %{})

        Mix.shell().info(
          Enum.join(
            [
              "artifact doctor:",
              "enabled=#{safe_value(doctor, :enabled?)}",
              "retention=#{safe_value(doctor, :retention_enabled?)}",
              "root_exists=#{safe_value(doctor, :root_exists?)}",
              "objects_root_exists=#{safe_value(doctor, :objects_root_exists?)}",
              "index_root_exists=#{safe_value(doctor, :index_root_exists?)}",
              "orphan_count=#{safe_value(gc_last_check, :orphan_count)}"
            ],
            " "
          )
        )

      {:ok, response} ->
        print_action_error("artifact doctor failed", response)
    end
  end

  def run(["rm", artifact_ref | _rest]) do
    Mix.Task.run("app.start")

    case Runner.run("delete_artifact", artifact_ref_params(artifact_ref), cli_context()) do
      {:ok, %{status: :needs_confirmation, confirmation_id: confirmation_id, artifact: artifact}} ->
        Mix.shell().info(
          "artifact delete needs confirmation: #{confirmation_id} #{short_sha(artifact.sha256)}"
        )

      {:ok, %{status: :completed, artifact: artifact}} ->
        Mix.shell().info("artifact deleted: #{short_sha(artifact.sha256)}")

      {:ok, response} ->
        print_action_error("artifact delete failed", response)
    end
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix allbert.artifacts list [--type MIME] [--origin ORIGIN] [--thread THREAD_ID] [--since DATE_OR_ISO] [--retention VALUE] [--lifecycle VALUE] [--limit N]
      mix allbert.artifacts show <sha|artifact://sha256/sha>
      mix allbert.artifacts threads <sha|artifact://sha256/sha>
      mix allbert.artifacts doctor
      mix allbert.artifacts rm <sha|artifact://sha256/sha>
    """)
  end

  defp list_params(rest) do
    case OptionParser.parse(rest,
           strict: [
             type: :string,
             mime: :string,
             origin: :string,
             thread: :string,
             thread_id: :string,
             since: :string,
             retention: :string,
             lifecycle: :string,
             limit: :integer
           ]
         ) do
      {opts, [], []} ->
        {:ok, normalize_list_opts(opts)}

      {_opts, extra, []} ->
        {:error, "unexpected arguments #{Enum.join(extra, " ")}"}

      {_opts, _extra, invalid} ->
        {:error, "invalid options #{inspect(invalid)}"}
    end
  end

  defp normalize_list_opts(opts) do
    opts
    |> Enum.flat_map(&normalize_list_opt/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_list_opt({:type, value}), do: [{:mime, value}]
  defp normalize_list_opt({:thread, value}), do: [{:thread_id, value}]
  defp normalize_list_opt({key, value}), do: [{key, value}]

  defp get_params("artifact://sha256/" <> _sha = uri),
    do: %{artifact_uri: uri, include_bytes: false}

  defp get_params(sha), do: %{sha256: sha, include_bytes: false}

  defp artifact_ref_params("artifact://sha256/" <> _sha = uri), do: %{artifact_uri: uri}
  defp artifact_ref_params(sha), do: %{sha256: sha}

  defp cli_context do
    %{
      actor: "local",
      user_id: "local",
      channel: :cli,
      request: %{
        user_id: "local",
        operator_id: "local",
        channel: :cli,
        source: :allbert_artifacts_cli
      }
    }
  end

  defp print_artifact_row(%{sha256: sha256, metadata: metadata}) do
    Mix.shell().info(
      Enum.join(
        [
          short_sha(sha256),
          "mime=#{metadata_value(metadata, :mime)}",
          "bytes=#{metadata_value(metadata, :byte_size)}",
          "origin=#{metadata_value(metadata, :origin)}",
          "retention=#{metadata_value(metadata, :retention)}",
          "lifecycle=#{metadata_value(metadata, :lifecycle)}",
          "created=#{metadata_value(metadata, :created_at)}"
        ],
        " "
      )
    )
  end

  defp print_artifact_detail(%{sha256: sha256, artifact_uri: artifact_uri, metadata: metadata}) do
    Mix.shell().info("sha=#{redacted(sha256)}")
    Mix.shell().info("uri=#{redacted(artifact_uri)}")
    Mix.shell().info("mime=#{metadata_value(metadata, :mime)}")
    Mix.shell().info("bytes=#{metadata_value(metadata, :byte_size)}")
    Mix.shell().info("origin=#{metadata_value(metadata, :origin)}")
    Mix.shell().info("retention=#{metadata_value(metadata, :retention)}")
    Mix.shell().info("lifecycle=#{metadata_value(metadata, :lifecycle)}")
    Mix.shell().info("redaction=#{metadata_value(metadata, :redaction_status)}")
    Mix.shell().info("created=#{metadata_value(metadata, :created_at)}")
  end

  defp print_thread_link(link) do
    Mix.shell().info(
      Enum.join(
        [
          "role=#{link_value(link, :role)}",
          "thread=#{link_value(link, :thread_id)}",
          "message=#{link_value(link, :message_id, "thread-level")}"
        ],
        " "
      )
    )
  end

  defp print_action_error(prefix, response) do
    error = Map.get(response, :error) || Map.get(response, :status, :unknown)
    Mix.shell().error("#{prefix}: #{inspect(Redactor.redact(error))}")
  end

  defp metadata_value(metadata, key, default \\ "-"), do: map_value(metadata, key, default)
  defp link_value(link, key, default \\ "-"), do: map_value(link, key, default)

  defp safe_value(map, key, default \\ "-"), do: map_value(map, key, default)

  defp map_value(map, key, default) when is_map(map) do
    map
    |> raw_map_value(key, default)
    |> redacted()
  end

  defp map_value(_map, _key, default), do: redacted(default)

  defp raw_map_value(map, key, default) when is_map(map) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), default)) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  defp raw_map_value(_map, _key, default), do: default

  defp redacted(value) do
    value
    |> Redactor.redact()
    |> to_cli_string()
  end

  defp to_cli_string(nil), do: "-"
  defp to_cli_string(value) when is_binary(value), do: value
  defp to_cli_string(value) when is_atom(value), do: Atom.to_string(value)
  defp to_cli_string(value), do: inspect(value)

  defp short_sha(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short_sha(_value), do: "-"
end
