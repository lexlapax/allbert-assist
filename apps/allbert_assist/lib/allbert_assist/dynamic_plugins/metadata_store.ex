defmodule AllbertAssist.DynamicPlugins.MetadataStore do
  @moduledoc """
  File-backed metadata store for v0.37 dynamic drafts.

  Plain module because this is deterministic Allbert Home file IO with no
  authoritative in-memory state. A `GenServer` would add ceremony without a
  useful state-machine successor.
  """

  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.YamlCodec

  @metadata_file "metadata.yaml"
  @manifest_file "manifest.yaml"

  @doc "Create or rewrite one draft metadata root."
  @spec put_draft(map() | Draft.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  def put_draft(attrs_or_draft, opts \\ [])

  def put_draft(%Draft{} = draft, _opts) do
    root = draft_root(draft.slug)
    draft = %{draft | root: root}

    with :ok <- File.mkdir_p(root),
         :ok <- write_yaml(Path.join(root, @metadata_file), Draft.to_metadata_map(draft)) do
      {:ok, draft}
    end
  end

  def put_draft(attrs, opts) when is_map(attrs) do
    with {:ok, draft} <- Draft.new(attrs, opts) do
      put_draft(draft, opts)
    end
  end

  @doc "Read one draft by slug."
  @spec get_draft(String.t()) :: {:ok, Draft.t()} | {:error, term()}
  def get_draft(slug) when is_binary(slug) do
    with :ok <- validate_slug(slug),
         {:ok, map} <- read_yaml(Path.join(draft_root(slug), @metadata_file)),
         {:ok, draft} <- Draft.new(Map.put(map, "root", draft_root(slug))) do
      {:ok, draft}
    end
  end

  @doc "List all readable draft metadata entries."
  @spec list_drafts() :: [Draft.t()]
  def list_drafts do
    drafts_root()
    |> child_names()
    |> Enum.flat_map(fn slug ->
      case get_draft(slug) do
        {:ok, draft} -> [draft]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&{&1.slug, &1.revision})
  end

  @doc "Read one integrated artifact by slug and optional revision."
  @spec get_integration(String.t(), String.t() | nil) :: {:ok, Draft.t()} | {:error, term()}
  def get_integration(slug, revision \\ nil) when is_binary(slug) do
    with :ok <- validate_slug(slug),
         {:ok, root} <- integration_root(slug, revision),
         {:ok, map} <- read_yaml(Path.join(root, @metadata_file)),
         {:ok, draft} <- Draft.new(Map.put(map, "root", root)) do
      {:ok, draft}
    end
  end

  @doc "Persist integrated artifact metadata under the integrated root."
  @spec put_integration(Draft.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  def put_integration(%Draft{} = draft, _opts \\ []) do
    root = integration_root_for(draft.slug, draft.revision)
    draft = %{draft | root: root}

    with :ok <- File.mkdir_p(root),
         :ok <- write_yaml(Path.join(root, @metadata_file), Draft.to_metadata_map(draft)) do
      {:ok, draft}
    end
  end

  @doc "List all readable integrated metadata entries."
  @spec list_integrations() :: [Draft.t()]
  def list_integrations do
    integrated_root()
    |> child_names()
    |> Enum.flat_map(fn slug ->
      slug
      |> integration_revision_roots()
      |> Enum.flat_map(&read_integration_root/1)
    end)
    |> Enum.sort_by(&{&1.slug, &1.revision})
  end

  @doc "Persist a draft tier transition."
  @spec transition_tier(String.t(), String.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  def transition_tier(slug, tier, opts \\ []) do
    with {:ok, draft} <- get_draft(slug),
         {:ok, draft} <- Draft.put_tier(draft, tier, opts) do
      put_draft(draft, opts)
    end
  end

  @doc "Mark a non-integrated draft as discarded."
  @spec discard_draft(String.t(), keyword()) :: {:ok, Draft.t()} | {:error, term()}
  def discard_draft(slug, opts \\ []), do: transition_tier(slug, "discarded", opts)

  @doc "Return current source hashes for the paths declared by a draft."
  @spec source_hashes(Draft.t()) :: {:ok, map()} | {:error, term()}
  def source_hashes(%Draft{} = draft) do
    Enum.reduce_while(Map.keys(draft.source_hashes), {:ok, %{}}, fn relative_path, {:ok, acc} ->
      with {:ok, path} <- safe_join(draft.root || draft_root(draft.slug), relative_path),
           {:ok, hash} <- hash_file(path) do
        {:cont, {:ok, Map.put(acc, relative_path, hash)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Verify stored source hashes against current files."
  @spec verify_source_hashes(Draft.t()) :: :ok | {:error, term()}
  def verify_source_hashes(%Draft{} = draft) do
    with {:ok, current} <- source_hashes(draft) do
      mismatches =
        draft.source_hashes
        |> Enum.reject(fn {path, hash} -> Map.get(current, path) == hash end)
        |> Enum.map(fn {path, expected} ->
          %{path: path, expected: expected, actual: Map.get(current, path)}
        end)

      if mismatches == [], do: :ok, else: {:error, {:source_hash_mismatch, mismatches}}
    end
  end

  @doc "Hash one file as the v0.37 source hash string."
  @spec hash_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_file(path) do
    case File.read(path) do
      {:ok, bytes} ->
        hash =
          :sha256
          |> :crypto.hash(bytes)
          |> Base.encode16(case: :lower)

        {:ok, "sha256:" <> hash}

      {:error, reason} ->
        {:error, {:file_read_failed, path, reason}}
    end
  end

  @doc "Write manifest data beside metadata."
  def put_manifest(slug, manifest) when is_binary(slug) and is_map(manifest) do
    with :ok <- validate_slug(slug),
         :ok <- File.mkdir_p(draft_root(slug)) do
      write_yaml(Path.join(draft_root(slug), @manifest_file), manifest)
    end
  end

  @doc "Write manifest data beside integrated metadata."
  def put_integration_manifest(slug, revision, manifest)
      when is_binary(slug) and is_binary(revision) and is_map(manifest) do
    with :ok <- validate_slug(slug),
         root <- integration_root_for(slug, revision),
         :ok <- File.mkdir_p(root) do
      write_yaml(Path.join(root, @manifest_file), manifest)
    end
  end

  @doc "Read manifest data beside metadata."
  def get_manifest(slug) when is_binary(slug) do
    with :ok <- validate_slug(slug) do
      read_yaml(Path.join(draft_root(slug), @manifest_file))
    end
  end

  @doc "Read manifest data beside integrated metadata."
  def get_integration_manifest(slug, revision) when is_binary(slug) do
    with :ok <- validate_slug(slug),
         {:ok, root} <- integration_root(slug, revision) do
      read_yaml(Path.join(root, @manifest_file))
    end
  end

  @doc "Return draft root for one slug."
  @spec draft_root(String.t()) :: String.t()
  def draft_root(slug), do: Path.join(drafts_root(), slug)

  @doc "Return the dynamic drafts root."
  @spec drafts_root() :: String.t()
  def drafts_root, do: Paths.dynamic_plugins_drafts_root()

  @doc "Return the dynamic integrated root."
  @spec integrated_root() :: String.t()
  def integrated_root, do: Paths.dynamic_plugins_integrated_root()

  @doc "Return integrated root for one slug/revision."
  @spec integration_root_for(String.t(), String.t()) :: String.t()
  def integration_root_for(slug, revision), do: Path.join([integrated_root(), slug, revision])

  defp read_integration_root(root) do
    case read_yaml(Path.join(root, @metadata_file)) do
      {:ok, map} ->
        case Draft.new(Map.put(map, "root", root)) do
          {:ok, draft} -> [draft]
          {:error, _reason} -> []
        end

      {:error, _reason} ->
        []
    end
  end

  defp integration_root(slug, nil) do
    case integration_revision_roots(slug) do
      [] -> {:error, :integration_not_found}
      roots -> {:ok, Enum.max_by(roots, &Path.basename/1)}
    end
  end

  defp integration_root(slug, revision) when is_binary(revision) do
    root = integration_root_for(slug, revision)

    if File.dir?(root), do: {:ok, root}, else: {:error, :integration_not_found}
  end

  defp integration_revision_roots(slug) do
    root = Path.join(integrated_root(), slug)

    root
    |> child_names()
    |> Enum.map(&Path.join(root, &1))
  end

  defp read_yaml(path) do
    if File.regular?(path) do
      YamlCodec.read_file(path)
    else
      {:error, {:metadata_not_found, path}}
    end
  end

  defp write_yaml(path, map) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, YamlCodec.encode!(map))
    end
  end

  defp child_names(root) do
    case File.ls(root) do
      {:ok, names} -> Enum.filter(names, &File.dir?(Path.join(root, &1)))
      {:error, _reason} -> []
    end
  end

  defp safe_join(root, relative_path) do
    root = Path.expand(root)
    path = Path.expand(Path.join(root, relative_path))

    if path == root or String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, {:path_outside_draft_root, relative_path}}
    end
  end

  defp validate_slug(slug) do
    case Draft.new(%{"slug" => slug, "revision" => "validation"}) do
      {:ok, _draft} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
