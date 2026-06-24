defmodule AllbertAssist.Coding.FileEffects do
  @moduledoc """
  Cwd-jailed file write/edit effects for v0.57 coding actions.

  The action modules own confirmation and Security Central decisions. This module
  owns only deterministic file validation, mutation, and redacted diff previews.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Runtime.Redactor

  @diff_max_bytes 8_000

  @type effect_summary :: %{
          required(:relative_path) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:content_sha256) => String.t(),
          required(:diff) => String.t(),
          required(:diff_truncated?) => boolean()
        }

  @doc "Create a new file inside the cwd jail. Existing files are refused."
  @spec write_file(term(), term(), map(), keyword()) :: {:ok, effect_summary()} | {:error, term()}
  def write_file(path, content, context \\ %{}, opts \\ []) do
    content = normalize_text(content)
    max_bytes = positive_integer(Keyword.get(opts, :max_bytes, Config.write_max_bytes()), 1)

    with :ok <- ensure_content_size(content, max_bytes),
         {:ok, destination} <- PathPolicy.resolve_new_file(path, context),
         :ok <- write_new_file(destination.path, content) do
      {:ok,
       %{
         relative_path: destination.relative_path,
         byte_size: byte_size(content),
         content_sha256: sha256(content),
         diff: diff(:write, destination.relative_path, "", content, 1),
         diff_truncated?: diff_truncated?(:write, destination.relative_path, "", content, 1)
       }}
    end
  end

  @doc "Apply an exact-match edit to an existing text file inside the cwd jail."
  @spec edit_file(term(), term(), term(), map(), keyword()) ::
          {:ok, effect_summary() | map()} | {:error, term()}
  def edit_file(path, old_text, new_text, context \\ %{}, opts \\ []) do
    old_text = normalize_text(old_text)
    new_text = normalize_text(new_text)
    max_bytes = positive_integer(Keyword.get(opts, :max_bytes, Config.write_max_bytes()), 1)

    max_replacements =
      positive_integer(
        Keyword.get(opts, :max_replacements, Config.edit_max_replacements()),
        1
      )

    with :ok <- ensure_nonempty_old_text(old_text),
         :ok <- ensure_content_size(new_text, max_bytes),
         {:ok, file} <- PathPolicy.resolve_file(path, context),
         :ok <- ensure_content_size(file.byte_size, max_bytes),
         :ok <- PathPolicy.ensure_text_file(file.path),
         {:ok, content} <- read_existing_file(file.path),
         {:ok, edited} <- apply_exact_replacement(content, old_text, new_text, max_replacements),
         :ok <- ensure_content_size(edited.content, max_bytes),
         :ok <- File.write(file.path, edited.content, [:binary]) do
      {:ok,
       %{
         relative_path: file.relative_path,
         byte_size: byte_size(edited.content),
         previous_byte_size: byte_size(content),
         content_sha256: sha256(edited.content),
         previous_content_sha256: sha256(content),
         replacements: edited.replacements,
         diff: diff(:edit, file.relative_path, old_text, new_text, edited.replacements),
         diff_truncated?:
           diff_truncated?(
             :edit,
             file.relative_path,
             old_text,
             new_text,
             edited.replacements
           )
       }}
    end
  end

  @doc "Return a redacted, bounded diff preview without mutating files."
  @spec diff(atom(), String.t(), String.t(), String.t(), pos_integer()) :: String.t()
  def diff(kind, relative_path, old_text, new_text, replacements \\ 1) do
    kind
    |> raw_diff(relative_path, old_text, new_text, replacements)
    |> Redactor.redact()
    |> truncate_diff()
  end

  @doc "Return whether the rendered diff preview is truncated."
  @spec diff_truncated?(atom(), String.t(), String.t(), String.t(), pos_integer()) :: boolean()
  def diff_truncated?(kind, relative_path, old_text, new_text, replacements \\ 1) do
    kind
    |> raw_diff(relative_path, old_text, new_text, replacements)
    |> Redactor.redact()
    |> byte_size()
    |> Kernel.>(@diff_max_bytes)
  end

  @doc "Return a stable content hash suitable for summaries."
  @spec sha256(String.t()) :: String.t()
  def sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp normalize_text(value) when is_binary(value), do: value
  defp normalize_text(nil), do: ""
  defp normalize_text(value), do: to_string(value)

  defp ensure_nonempty_old_text(""), do: {:error, :empty_exact_match}
  defp ensure_nonempty_old_text(_old_text), do: :ok

  defp ensure_content_size(content, max_bytes) when is_binary(content) do
    ensure_content_size(byte_size(content), max_bytes)
  end

  defp ensure_content_size(size, max_bytes) when is_integer(size) and size <= max_bytes, do: :ok

  defp ensure_content_size(size, max_bytes) when is_integer(size),
    do: {:error, {:content_too_large, size, max_bytes}}

  defp write_new_file(path, content) do
    case File.open(path, [:write, :binary, :exclusive], fn io -> IO.binwrite(io, content) end) do
      {:ok, :ok} -> :ok
      {:error, :eexist} -> {:error, :file_exists}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp read_existing_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp apply_exact_replacement(content, old_text, new_text, max_replacements) do
    matches = :binary.matches(content, old_text)
    count = length(matches)

    cond do
      count == 0 ->
        {:error, :exact_match_not_found}

      count > max_replacements ->
        {:error, {:too_many_exact_matches, count, max_replacements}}

      true ->
        {:ok,
         %{
           content: String.replace(content, old_text, new_text, global: true),
           replacements: count
         }}
    end
  end

  defp raw_diff(:write, relative_path, _old_text, new_text, _replacements) do
    [
      "diff --git a/",
      relative_path,
      " b/",
      relative_path,
      "\nnew file mode 100644\n--- /dev/null\n+++ b/",
      relative_path,
      "\n@@\n",
      prefix_lines("+", new_text)
    ]
    |> IO.iodata_to_binary()
  end

  defp raw_diff(:edit, relative_path, old_text, new_text, replacements) do
    [
      "diff --git a/",
      relative_path,
      " b/",
      relative_path,
      "\n--- a/",
      relative_path,
      "\n+++ b/",
      relative_path,
      "\n@@ exact replacements=",
      Integer.to_string(replacements),
      "\n",
      prefix_lines("-", old_text),
      prefix_lines("+", new_text)
    ]
    |> IO.iodata_to_binary()
  end

  defp raw_diff(_kind, relative_path, old_text, new_text, replacements),
    do: raw_diff(:edit, relative_path, old_text, new_text, replacements)

  defp prefix_lines(prefix, text) do
    lines = String.split(text, "\n", trim: false)
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {"", index} when index == last_index -> ""
      {line, _index} -> [prefix, line, "\n"]
    end)
  end

  defp truncate_diff(diff) do
    if byte_size(diff) > @diff_max_bytes do
      binary_part(diff, 0, @diff_max_bytes) <> "\n[diff truncated]"
    else
      diff
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
