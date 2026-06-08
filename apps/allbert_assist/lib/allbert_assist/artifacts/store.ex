defmodule AllbertAssist.Artifacts.Store do
  @moduledoc """
  Content-addressable object storage under the Allbert artifacts root.

  Objects are addressed by lowercase SHA-256, stored below a two-level shard
  path, and written through a temporary file followed by `File.rename/2`.
  """

  alias AllbertAssist.Artifacts.Config

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @type object :: %{
          required(:sha256) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:path) => String.t(),
          required(:deduped?) => boolean()
        }

  @doc "Hash a binary as lowercase SHA-256."
  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end

  @doc "Hash an enumerable stream of binary chunks as lowercase SHA-256."
  @spec sha256_stream(Enumerable.t()) :: String.t()
  def sha256_stream(chunks) do
    chunks
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
      :crypto.hash_update(context, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Persist a binary object and return its content-addressable location."
  @spec put(binary(), keyword()) :: {:ok, object()} | {:error, term()}
  def put(bytes, opts \\ []) when is_binary(bytes) do
    sha256 = sha256(bytes)
    path = object_path!(sha256, opts)

    if File.exists?(path) do
      {:ok, object(sha256, byte_size(bytes), path, true)}
    else
      write_object(bytes, sha256, path)
    end
  end

  @doc "Read a persisted object by lowercase SHA-256."
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read(sha256, opts \\ []) do
    with {:ok, path} <- object_path(sha256, opts) do
      case File.read(path) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Return whether an object exists for a lowercase SHA-256."
  @spec exists?(String.t(), keyword()) :: boolean()
  def exists?(sha256, opts \\ []) do
    case object_path(sha256, opts) do
      {:ok, path} -> File.exists?(path)
      {:error, _reason} -> false
    end
  end

  @doc "Delete a persisted object by lowercase SHA-256."
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(sha256, opts \\ []) do
    with {:ok, path} <- object_path(sha256, opts) do
      case File.rm(path) do
        :ok ->
          {:ok, %{sha256: sha256, path: path, deleted?: true}}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "List object SHA-256 digests currently present in the object tree."
  @spec list_objects(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_objects(opts \\ []) do
    opts
    |> objects_root()
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.filter(&valid_sha256?/1)
    |> Enum.sort()
    |> then(&{:ok, &1})
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  @doc "Return an object path when the SHA-256 is valid."
  @spec object_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, :invalid_sha256}
  def object_path(sha256, opts \\ []) do
    if valid_sha256?(sha256) do
      {:ok,
       Path.join([
         root(opts),
         "objects",
         String.slice(sha256, 0, 2),
         String.slice(sha256, 2, 2),
         sha256
       ])}
    else
      {:error, :invalid_sha256}
    end
  end

  @doc "Return an object path or raise when the SHA-256 is invalid."
  @spec object_path!(String.t(), keyword()) :: String.t()
  def object_path!(sha256, opts \\ []) do
    case object_path(sha256, opts) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, "invalid artifact sha256: #{inspect(reason)}"
    end
  end

  @doc "Return whether a value is a lowercase SHA-256 digest."
  @spec valid_sha256?(term()) :: boolean()
  def valid_sha256?(sha256) when is_binary(sha256), do: Regex.match?(@sha256_pattern, sha256)
  def valid_sha256?(_sha256), do: false

  @doc "Return the artifacts root for an operation."
  @spec root(keyword()) :: String.t()
  def root(opts \\ []) do
    opts
    |> Keyword.get(:root)
    |> case do
      nil -> Config.root()
      path when is_binary(path) -> Path.expand(path)
    end
  end

  defp objects_root(opts), do: Path.join(root(opts), "objects")

  defp write_object(bytes, sha256, path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = Path.join(dir, ".#{sha256}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.write(tmp_path, bytes, [:binary]),
         :ok <- File.rename(tmp_path, path) do
      {:ok, object(sha256, byte_size(bytes), path, false)}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp object(sha256, byte_size, path, deduped?) do
    %{
      sha256: sha256,
      byte_size: byte_size,
      path: path,
      deduped?: deduped?
    }
  end
end
