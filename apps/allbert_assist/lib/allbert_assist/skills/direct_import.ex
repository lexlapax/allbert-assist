defmodule AllbertAssist.Skills.DirectImport do
  @moduledoc """
  URI-backed direct skill import materialization helpers.

  The functions in this module fetch or read inert skill content only after an
  action boundary has performed Security Central checks and confirmation/grant
  handling. They never trust, enable, activate, execute scripts, or install
  dependencies.
  """

  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Settings

  @default_max_import_bytes 1_048_576

  @spec fetch_remote(RequestSpec.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch_remote(%RequestSpec{} = spec, context \\ %{}) do
    with :ok <- require_https(spec),
         {:ok, response} <- request(spec, context),
         :ok <- success_status(response.status),
         {:ok, body} <- response_body(response.body, spec.max_response_bytes),
         {:ok, files} <- files_from_remote_body(body) do
      {:ok, remote_detail(spec, files)}
    end
  end

  @spec collect_local(term(), map()) :: {:ok, map()} | {:error, term()}
  def collect_local(path, opts \\ %{}) do
    with {:ok, root} <- canonical_root(path),
         :ok <- require_directory(root),
         {:ok, files} <- read_tree(root, max_import_bytes(opts)),
         :ok <- require_skill_md(files) do
      {:ok, local_detail(root, files)}
    end
  end

  defp require_https(%RequestSpec{uri: %URI{scheme: "https"}}), do: :ok

  defp require_https(%RequestSpec{url: url}),
    do: {:error, {:unsupported_skill_import_scheme, url}}

  defp request(%RequestSpec{} = spec, context) do
    spec
    |> req_options(context)
    |> Req.request()
    |> case do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:remote_skill_transport_error, error.reason}}

      {:error, reason} ->
        {:error, {:remote_skill_request_failed, reason}}
    end
  end

  defp req_options(spec, context) do
    [
      method: :get,
      url: spec.url,
      headers: spec.headers,
      receive_timeout: spec.timeout_ms,
      retry: false,
      redirect: spec.allow_redirects?,
      max_redirects: spec.max_redirects
    ]
    |> Keyword.merge(app_req_options())
    |> maybe_put(:plug, req_plug(context))
  end

  defp app_req_options do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp req_plug(context) do
    get_in(context, [:direct_import, :req_plug]) ||
      get_in(context, ["direct_import", "req_plug"]) ||
      get_in(context, [:external, :req_plug]) ||
      get_in(context, ["external", "req_plug"])
  end

  defp success_status(status) when is_integer(status) and status in 200..299, do: :ok
  defp success_status(status), do: {:error, {:remote_skill_http_error, status}}

  defp response_body(body, cap) do
    body = body_to_binary(body)

    if byte_size(body) > cap do
      {:error, {:remote_skill_response_too_large, byte_size(body), cap}}
    else
      {:ok, body}
    end
  end

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(nil), do: ""

  defp body_to_binary(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(body)
    end
  end

  defp files_from_remote_body(body) do
    case Jason.decode(body) do
      {:ok, %{"files" => files}} when is_map(files) ->
        files
        |> stringify_files()
        |> require_skill_md()
        |> case do
          :ok -> {:ok, stringify_files(files)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:ok, %{"SKILL.md" => body}}
    end
  end

  defp canonical_root(path) do
    with {:ok, resource_uri} <- ResourceURI.file(path),
         {:ok, root} <- ResourceURI.path_from_file_uri(resource_uri) do
      {:ok, root}
    end
  end

  defp require_directory(root) do
    cond do
      File.dir?(root) -> :ok
      File.exists?(root) -> {:error, {:local_skill_import_not_directory, root}}
      true -> {:error, {:local_skill_import_path_not_found, root}}
    end
  end

  defp read_tree(root, cap) do
    with {:ok, files, _bytes} <- walk(root, root, %{}, 0, cap) do
      {:ok, files}
    end
  end

  defp walk(path, root, files, bytes, cap) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:error, {:unsafe_local_skill_symlink, relative_path(root, path)}}

      {:ok, %{type: :directory}} ->
        walk_directory(path, root, files, bytes, cap)

      {:ok, %{type: :regular, size: size}} ->
        with :ok <- safe_relative_path(root, path),
             :ok <- cap_available(bytes, size, cap),
             {:ok, content} <- File.read(path) do
          {:ok, Map.put(files, relative_path(root, path), content), bytes + byte_size(content)}
        end

      {:ok, %{type: type}} ->
        {:error, {:unsupported_local_skill_resource, relative_path(root, path), type}}

      {:error, reason} ->
        {:error, {:local_skill_resource_unreadable, relative_path(root, path), reason}}
    end
  end

  defp walk_directory(path, root, files, bytes, cap) do
    with :ok <- safe_relative_path(root, path),
         {:ok, entries} <- File.ls(path) do
      entries
      |> Enum.sort()
      |> Enum.reduce_while({:ok, files, bytes}, &walk_entry(&1, path, root, cap, &2))
    end
  end

  defp walk_entry(entry, path, root, cap, {:ok, files, bytes}) do
    case walk(Path.join(path, entry), root, files, bytes, cap) do
      {:ok, next_files, next_bytes} -> {:cont, {:ok, next_files, next_bytes}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp safe_relative_path(root, path) do
    relative_path(root, path)
    |> unsafe_path?()
    |> case do
      false -> :ok
      true -> {:error, {:unsafe_local_skill_path, relative_path(root, path)}}
    end
  end

  defp unsafe_path?("."), do: false

  defp unsafe_path?(path) do
    path == "" or Path.type(path) == :absolute or String.contains?(path, ["..", "\\"]) or
      path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp relative_path(root, path), do: Path.relative_to(path, root)

  defp cap_available(bytes, size, cap) when bytes + size <= cap, do: :ok

  defp cap_available(bytes, size, cap),
    do: {:error, {:local_skill_import_too_large, bytes + size, cap}}

  defp require_skill_md(%{"SKILL.md" => content}) when is_binary(content), do: :ok
  defp require_skill_md(_files), do: {:error, :missing_skill_md}

  defp stringify_files(files) do
    Map.new(files, fn {path, content} -> {to_string(path), body_to_binary(content)} end)
  end

  defp remote_detail(%RequestSpec{} = spec, files) do
    %{
      id: spec.url,
      source_url: spec.url,
      fetched_at: timestamp(),
      candidate: %{
        id: spec.url,
        name: name_hint(spec.path),
        owner: "direct-url",
        repository: spec.host,
        source: "direct_url"
      },
      files: files,
      skill_md: Map.get(files, "SKILL.md"),
      source: source_summary(:remote_url, spec.url)
    }
  end

  defp local_detail(root, files) do
    resource_uri = ResourceURI.file!(root)

    %{
      id: resource_uri,
      source_url: resource_uri,
      fetched_at: timestamp(),
      local_root: root,
      candidate: %{
        id: resource_uri,
        name: Path.basename(root),
        owner: "local-directory",
        repository: Path.basename(Path.dirname(root)),
        source: "local_directory"
      },
      files: files,
      skill_md: Map.get(files, "SKILL.md"),
      source: source_summary(:local_directory, resource_uri)
    }
  end

  @spec source_summary(:remote_url | :local_directory, String.t()) :: map()
  def source_summary(:remote_url, url) do
    uri = URI.parse(url)

    %{
      id: "direct_url",
      kind: :remote_url,
      url: url,
      base_url: "#{uri.scheme}://#{uri.host}"
    }
  end

  def source_summary(:local_directory, resource_uri) do
    %{
      id: "local_directory",
      kind: :local_directory,
      url: resource_uri,
      base_url: resource_uri
    }
  end

  defp name_hint(path) do
    path
    |> to_string()
    |> Path.basename()
    |> String.replace_suffix(".md", "")
    |> case do
      "" -> "skill"
      name -> name
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp max_import_bytes(opts) do
    Map.get(opts, :max_import_bytes) || setting("skills.online_import.max_download_bytes") ||
      @default_max_import_bytes
  end

  defp setting(key) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
end
