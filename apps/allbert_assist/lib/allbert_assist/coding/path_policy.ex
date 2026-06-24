defmodule AllbertAssist.Coding.PathPolicy do
  @moduledoc """
  Cwd-jail and bounded-read policy for v0.57 coding tools.

  This module is intentionally read/write agnostic. M1 uses it for read-only
  actions; M2 reuses the same normalization and symlink checks for writes.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Runtime.Redactor

  @binary_probe_bytes 4_096

  @type file_summary :: %{
          required(:path) => String.t(),
          required(:relative_path) => String.t(),
          required(:byte_size) => non_neg_integer()
        }
  @type dir_summary :: %{
          required(:path) => String.t(),
          required(:relative_path) => String.t(),
          required(:jail) => String.t()
        }
  @type read_summary :: %{
          required(:path) => String.t(),
          required(:relative_path) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:content) => String.t(),
          required(:offset) => non_neg_integer(),
          required(:limit) => pos_integer(),
          required(:max_bytes) => pos_integer(),
          required(:returned_lines) => non_neg_integer(),
          required(:returned_bytes) => non_neg_integer(),
          required(:truncated?) => boolean()
        }

  @doc "Resolve the current coding cwd jail to a real directory path."
  @spec jail(map()) :: {:ok, String.t()} | {:error, term()}
  def jail(context \\ %{}) do
    context
    |> Config.cwd_jail()
    |> expand_jail()
  end

  @doc "Resolve an existing file path inside the cwd jail."
  @spec resolve_file(term(), map()) :: {:ok, file_summary()} | {:error, term()}
  def resolve_file(path, context \\ %{}) do
    with {:ok, jail} <- jail(context),
         {:ok, expanded} <- expand_inside_jail(path, jail),
         :ok <- ensure_inside_jail(expanded, jail),
         {:ok, real_path} <- realpath(expanded),
         :ok <- ensure_inside_jail(real_path, jail),
         {:ok, stat} <- File.stat(real_path),
         :regular <- stat.type do
      {:ok,
       %{path: real_path, relative_path: relative_path(real_path, jail), byte_size: stat.size}}
    else
      {:error, reason} -> {:error, reason}
      type when is_atom(type) -> {:error, {:not_a_file, type}}
    end
  end

  @doc "Resolve an existing directory path inside the cwd jail."
  @spec resolve_dir(term(), map()) :: {:ok, dir_summary()} | {:error, term()}
  def resolve_dir(path, context \\ %{}) do
    with {:ok, jail} <- jail(context),
         {:ok, expanded} <- expand_inside_jail(path || ".", jail),
         :ok <- ensure_inside_jail(expanded, jail),
         {:ok, real_path} <- realpath(expanded),
         :ok <- ensure_inside_jail(real_path, jail),
         {:ok, stat} <- File.stat(real_path),
         :directory <- stat.type do
      {:ok, %{path: real_path, relative_path: relative_path(real_path, jail), jail: jail}}
    else
      {:error, reason} -> {:error, reason}
      type when is_atom(type) -> {:error, {:not_a_directory, type}}
    end
  end

  @doc "Return true when a path is inside the resolved cwd jail."
  @spec inside_jail?(String.t(), String.t()) :: boolean()
  def inside_jail?(path, jail) when is_binary(path) and is_binary(jail) do
    path = Path.expand(path)
    jail = Path.expand(jail)

    path == jail or String.starts_with?(path, jail <> "/")
  end

  @doc "Return a jail-relative path for result rendering."
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(path, jail) do
    relative = Path.relative_to(path, jail)
    if relative == ".", do: "", else: relative
  end

  @doc "Read a bounded text chunk from a file inside the cwd jail."
  @spec read_file(term(), map(), keyword()) :: {:ok, read_summary()} | {:error, term()}
  def read_file(path, context \\ %{}, opts \\ []) do
    offset = non_negative_integer(Keyword.get(opts, :offset, 0), 0)
    limit = positive_integer(Keyword.get(opts, :limit, Config.read_default_limit()), 1)
    max_bytes = positive_integer(Keyword.get(opts, :max_bytes, Config.read_max_bytes()), 1)

    with {:ok, file} <- resolve_file(path, context),
         :ok <- ensure_text_file(file.path),
         {:ok, chunk} <- read_chunk(file.path, offset, limit, max_bytes) do
      {:ok, Map.merge(file, chunk)}
    end
  end

  defp expand_jail(path) when is_binary(path) do
    expanded = Path.expand(path, File.cwd!())

    with {:ok, stat} <- File.stat(expanded),
         :directory <- stat.type,
         {:ok, real_path} <- realpath(expanded) do
      {:ok, real_path}
    else
      {:error, reason} -> {:error, {:invalid_cwd_jail, reason}}
      type when is_atom(type) -> {:error, {:invalid_cwd_jail_type, type}}
    end
  end

  defp expand_inside_jail(path, jail) when is_binary(path) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, jail)
      end

    {:ok, expanded}
  end

  defp expand_inside_jail(_path, _jail), do: {:error, :invalid_path}

  defp ensure_inside_jail(path, jail) do
    if inside_jail?(path, jail), do: :ok, else: {:error, :path_outside_cwd_jail}
  end

  defp realpath(path), do: {:ok, resolve_symlink_path(path, 0)}

  defp resolve_symlink_path(path, depth) when depth > 40, do: Path.expand(path)

  defp resolve_symlink_path(path, depth) do
    case Path.split(Path.expand(path)) do
      ["/" | parts] -> resolve_symlink_parts(parts, "/", depth)
      parts -> resolve_symlink_parts(parts, Path.expand("."), depth)
    end
  end

  defp resolve_symlink_parts([], path, _depth), do: path

  defp resolve_symlink_parts([part | rest], base, depth) do
    candidate = Path.join(base, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target
        |> expand_symlink_target(base)
        |> append_path_parts(rest)
        |> resolve_symlink_path(depth + 1)

      {:error, :enoent} ->
        append_path_parts(candidate, rest)

      {:error, _reason} ->
        resolve_symlink_parts(rest, candidate, depth)
    end
  end

  defp expand_symlink_target(target, base) do
    if Path.type(target) == :absolute do
      Path.expand(target)
    else
      Path.expand(target, base)
    end
  end

  defp append_path_parts(path, parts) do
    Enum.reduce(parts, path, fn part, acc -> Path.join(acc, part) end)
  end

  defp ensure_text_file(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, @binary_probe_bytes) end) do
      {:ok, sample} when is_binary(sample) ->
        if :binary.match(sample, <<0>>) == :nomatch do
          :ok
        else
          {:error, :binary_file}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp read_chunk(path, offset, limit, max_bytes) do
    state = %{line: 0, taken: 0, bytes: 0, lines: [], truncated?: false}

    result =
      path
      |> File.stream!(:line, [])
      |> Enum.reduce_while(state, fn line, acc ->
        line_number = acc.line + 1
        acc = %{acc | line: line_number}

        cond do
          line_number <= offset ->
            {:cont, acc}

          acc.taken >= limit ->
            {:halt, %{acc | truncated?: true}}

          acc.bytes + byte_size(line) > max_bytes ->
            {:halt, %{acc | truncated?: true}}

          true ->
            {:cont,
             %{
               acc
               | taken: acc.taken + 1,
                 bytes: acc.bytes + byte_size(line),
                 lines: [line | acc.lines]
             }}
        end
      end)

    content =
      result.lines
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> Redactor.redact()

    {:ok,
     %{
       content: content,
       offset: offset,
       limit: limit,
       max_bytes: max_bytes,
       returned_lines: result.taken,
       returned_bytes: byte_size(content),
       truncated?: result.truncated?
     }}
  rescue
    exception -> {:error, {:read_failed, exception.__struct__}}
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default
end
