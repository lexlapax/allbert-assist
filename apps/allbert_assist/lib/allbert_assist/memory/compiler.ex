defmodule AllbertAssist.Memory.Compiler do
  @moduledoc """
  Builds derived memory index and category summary artifacts.
  """

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Index

  @header "# DERIVED - DO NOT EDIT"

  @spec compile_index(String.t(), keyword()) ::
          {:ok,
           %{
             path: String.t(),
             entry_count: non_neg_integer(),
             categories: [String.t()],
             derived_at: String.t(),
             elapsed_ms: integer()
           }}
          | {:error, term()}
  def compile_index(root, opts \\ []) when is_binary(root) do
    started = System.monotonic_time(:millisecond)

    with {:ok, index} <- Index.build(root, opts),
         {:ok, encoded} <- Index.encode(index),
         :ok <- File.write(Index.path(root), encoded) do
      {:ok,
       %{
         path: Index.path(root),
         entry_count: index["entry_count"],
         categories: categories_covered(index),
         derived_at: index["derived_at"],
         elapsed_ms: System.monotonic_time(:millisecond) - started
       }}
    end
  end

  @spec summarize_category(String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def summarize_category(root, category, opts \\ [])

  def summarize_category(root, category, opts) when is_binary(root) and is_atom(category) do
    user_id = Keyword.get(opts, :user_id)

    with {:ok, entries} <- Memory.list_entries(category: category, user_id: user_id, limit: 500),
         summary <- render_summary(root, category, entries),
         path <- Path.join([root, Atom.to_string(category), ".summary.md"]),
         :ok <- File.write(path, summary) do
      {:ok,
       %{
         path: path,
         category: category,
         entry_count: length(entries),
         derived_at: derived_at_from_summary(summary),
         summary: summary
       }}
    end
  end

  def summarize_category(_root, _category, _opts), do: {:error, :invalid_category}

  defp categories_covered(index) do
    index
    |> Map.get("entries", [])
    |> Enum.map(& &1["category"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp render_summary(root, category, entries) do
    derived_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    table =
      entries
      |> Enum.map(fn entry ->
        "- #{entry.timestamp} | #{entry.review_status} | #{entry.summary} | #{entry.path}"
      end)
      |> Enum.join("\n")

    kept =
      entries
      |> Enum.filter(&(&1.review_status == :kept))
      |> Enum.take(5)
      |> Enum.map(fn entry ->
        "### #{entry.summary}\n\n#{entry.body}"
      end)
      |> Enum.join("\n\n")

    """
    #{@header}
    # Source: #{Path.join([root, Atom.to_string(category), "*.md"])}
    # Rebuilt: #{derived_at}

    # Memory Summary: #{category}

    ## Entries

    #{empty_if_blank(table)}

    ## Recently Reviewed Kept Entries

    #{empty_if_blank(kept)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp derived_at_from_summary(summary) do
    case Regex.run(~r/^# Rebuilt: (.+)$/m, summary) do
      [_, derived_at] -> String.trim(derived_at)
      _match -> nil
    end
  end

  defp empty_if_blank(""), do: "(none)"
  defp empty_if_blank(value), do: value
end
