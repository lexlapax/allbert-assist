defmodule AllbertNotesFiles.Notes do
  @moduledoc """
  Bounded local file access helpers for the notes/files reference plugin.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Settings

  @default_root "<ALLBERT_HOME>/notes"
  @default_max_results 25
  @max_results 100
  @max_read_bytes 64_000
  @extensions ~w[.md .markdown .txt]

  @type note_summary :: %{
          title: String.t(),
          path: String.t(),
          relative_path: String.t(),
          excerpt: String.t(),
          byte_size: non_neg_integer(),
          updated_at: String.t() | nil,
          resource_ref: map()
        }

  @spec root() :: String.t()
  def root do
    "apps.notes_files.notes_root"
    |> Settings.get()
    |> case do
      {:ok, value} when is_binary(value) and value != "" -> value
      _other -> @default_root
    end
    |> expand_path()
  end

  @spec max_results() :: pos_integer()
  def max_results do
    case Settings.get("apps.notes_files.max_results") do
      {:ok, value} when is_integer(value) and value > 0 -> min(value, @max_results)
      _other -> @default_max_results
    end
  end

  @spec ensure_root!() :: String.t()
  def ensure_root! do
    root = root()
    File.mkdir_p!(root)
    root
  end

  @spec search(term(), keyword()) :: {:ok, [note_summary()]}
  def search(query, opts \\ []) do
    root = ensure_root!()
    limit = opts |> Keyword.get(:limit, max_results()) |> normalize_limit()
    query = query |> to_string() |> String.trim() |> String.downcase()

    root
    |> note_files()
    |> Enum.flat_map(&summary_for(&1, root))
    |> Enum.filter(&matches?(&1, query))
    |> Enum.take(limit)
    |> then(&{:ok, &1})
  end

  @spec read(term()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    root = ensure_root!()

    with {:ok, path} <- resolve_existing_note_path(path, root),
         {:ok, body} <- read_bounded(path),
         [summary] <- summary_for(path, root) do
      {:ok,
       summary
       |> Map.put(:body, body)
       |> Map.put(:resource_refs, [resource_ref(path, :read)])}
    else
      [] -> {:error, :not_found}
      error -> error
    end
  end

  @spec prepare_write(map()) :: {:ok, map()} | {:error, term()}
  def prepare_write(params) when is_map(params) do
    root = ensure_root!()
    title = params |> field(:title) |> normalize_string()
    body = params |> field(:body) |> normalize_string()
    requested_path = field(params, :path)

    with {:ok, title} <- require_title(title),
         {:ok, body} <- require_body(body),
         {:ok, path} <- target_note_path(requested_path, title, root) do
      content = note_content(title, body)

      {:ok,
       %{
         app_id: :notes_files,
         title: title,
         body: body,
         content: content,
         path: path,
         relative_path: relative_path(path, root),
         resource_uri: ResourceURI.file!(path),
         resource_refs: [resource_ref(path, :write)]
       }}
    end
  end

  def prepare_write(_params), do: {:error, :invalid_params}

  @spec write_prepared(map()) :: {:ok, map()} | {:error, term()}
  def write_prepared(%{path: path, content: content} = request)
      when is_binary(path) and is_binary(content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok,
       request
       |> Map.drop([:content])
       |> Map.put(:status, :written)
       |> Map.put(:byte_size, byte_size(content))
       |> Map.put(:resource_refs, [resource_ref(path, :write)])}
    end
  end

  def write_prepared(_request), do: {:error, :invalid_write_request}

  @spec resource_ref(String.t(), :read | :write) :: map()
  def resource_ref(path, operation) when operation in [:read, :write] do
    operation_class = if operation == :write, do: :write_local_path, else: :read_local_path
    access_mode = if operation == :write, do: :write, else: :read

    Ref.new!(%{
      resource_uri: ResourceURI.file!(path),
      origin_kind: :local_path,
      operation_class: operation_class,
      access_mode: access_mode,
      scope: Scope.exact_file(path),
      downstream_consumer: :notes_files,
      limits: %{max_read_bytes: @max_read_bytes},
      metadata: %{app_id: :notes_files}
    })
    |> Ref.to_map()
  end

  @spec root_ref() :: map()
  def root_ref do
    root = root()

    Ref.new!(%{
      resource_uri: ResourceURI.file!(root),
      origin_kind: :local_path,
      operation_class: :read_local_path,
      access_mode: :read,
      scope: Scope.directory_subtree(root),
      downstream_consumer: :notes_files,
      limits: %{max_read_bytes: @max_read_bytes},
      metadata: %{app_id: :notes_files}
    })
    |> Ref.to_map()
  end

  defp note_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&(Path.extname(&1) in @extensions))
    |> Enum.reject(&hidden_path?(relative_path(&1, root)))
    |> Enum.sort_by(&mtime_unix/1, :desc)
  end

  defp summary_for(path, root) do
    with {:ok, body} <- read_bounded(path),
         {:ok, stat} <- File.stat(path, time: :posix) do
      [
        %{
          title: title(path, body),
          path: path,
          relative_path: relative_path(path, root),
          excerpt: excerpt(body),
          byte_size: stat.size,
          updated_at: updated_at(stat),
          resource_ref: resource_ref(path, :read)
        }
      ]
    else
      _error -> []
    end
  end

  defp matches?(_note, ""), do: true

  defp matches?(note, query) do
    haystack =
      [note.title, note.relative_path, note.excerpt]
      |> Enum.join("\n")
      |> String.downcase()

    String.contains?(haystack, query)
  end

  defp read_bounded(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_read_bytes || {:error, :note_too_large} do
      File.read(path)
    end
  end

  defp resolve_existing_note_path(path, root) do
    with {:ok, path} <- target_note_path(path, nil, root),
         true <- File.regular?(path) || {:error, :not_found} do
      {:ok, path}
    end
  end

  defp target_note_path(nil, title, root), do: target_note_path("", title, root)

  defp target_note_path(path, title, root) do
    path = path |> to_string() |> String.trim()

    candidate =
      cond do
        path == "" and is_binary(title) -> Path.join(root, slug(title) <> ".md")
        Path.type(path) == :absolute -> Path.expand(path)
        true -> Path.expand(path, root)
      end

    candidate =
      if Path.extname(candidate) == "" do
        candidate <> ".md"
      else
        candidate
      end

    cond do
      not inside_root?(candidate, root) -> {:error, :path_outside_notes_root}
      Path.extname(candidate) not in @extensions -> {:error, :unsupported_note_extension}
      true -> {:ok, candidate}
    end
  end

  defp title(path, body) do
    body
    |> String.split("\n", parts: 8)
    |> Enum.find_value(fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "#") do
        line
        |> String.trim_leading("#")
        |> String.trim()
        |> blank_to_nil()
      end
    end)
    |> case do
      nil -> path |> Path.basename() |> Path.rootname() |> humanize()
      value -> value
    end
  end

  defp excerpt(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.join(" ")
    |> case do
      "" -> "No note body."
      text -> String.slice(text, 0, 240)
    end
  end

  defp note_content(title, body) do
    body = String.trim(body)

    if String.starts_with?(body, "#") do
      body <> "\n"
    else
      "# #{title}\n\n#{body}\n"
    end
  end

  defp updated_at(%File.Stat{mtime: mtime}) do
    mtime
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  rescue
    _exception -> nil
  end

  defp mtime_unix(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _error -> 0
    end
  end

  defp relative_path(path, root), do: Path.relative_to(path, root)

  defp inside_root?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path != root and String.starts_with?(path, root <> "/")
  end

  defp hidden_path?(relative_path) do
    relative_path
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp expand_path(path) do
    path
    |> String.replace("<ALLBERT_HOME>", Paths.home())
    |> Path.expand()
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, @max_results)
  defp normalize_limit(_value), do: @default_max_results

  defp require_title(nil), do: {:error, :missing_title}
  defp require_title(title), do: {:ok, title}

  defp require_body(nil), do: {:error, :missing_body}
  defp require_body(body), do: {:ok, body}

  defp normalize_string(nil), do: nil

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "note-#{System.system_time(:second)}"
      slug -> String.slice(slug, 0, 80)
    end
  end

  defp humanize(value) do
    value
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
