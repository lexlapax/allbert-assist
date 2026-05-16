defmodule AllbertAssist.Memory.Review do
  @moduledoc """
  Helpers for parsing and writing markdown memory review sections.
  """

  alias AllbertAssist.Memory

  @statuses [:kept, :flagged, :prune_nominated]
  @review_header "## Review"

  @doc "Return accepted persisted review statuses."
  @spec statuses() :: [:kept | :flagged | :prune_nominated, ...]
  def statuses, do: @statuses

  @doc "Parse the optional markdown review section."
  @spec parse_review(String.t()) :: %{
          review_status: :unreviewed | :kept | :flagged | :prune_nominated,
          reviewed_at: String.t() | nil,
          reviewed_by: String.t() | nil,
          correction_note: String.t() | nil
        }
  def parse_review(content) when is_binary(content) do
    section = review_section(content)

    %{
      review_status: parse_status(metadata(section, "Status")),
      reviewed_at: nullable(metadata(section, "Reviewed")),
      reviewed_by: nullable(metadata(section, "Reviewed by")),
      correction_note: nullable(metadata(section, "Correction note"))
    }
  end

  @doc "Replace or append the markdown review section."
  @spec write_review(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_review(content, attrs) when is_binary(content) and is_map(attrs) do
    with {:ok, status} <- normalize_status(Map.get(attrs, :status, Map.get(attrs, "status"))) do
      reviewed_at =
        attrs
        |> Map.get(:reviewed_at, Map.get(attrs, "reviewed_at"))
        |> default_reviewed_at()

      reviewed_by =
        attrs
        |> Map.get(:reviewed_by, Map.get(attrs, "reviewed_by"))
        |> default_string("")

      note =
        attrs
        |> Map.get(:note, Map.get(attrs, :correction_note, Map.get(attrs, "correction_note")))
        |> default_string("")

      {:ok, replace_review_section(content, status, reviewed_at, reviewed_by, note)}
    end
  end

  def write_review(_content, _attrs), do: {:error, :invalid_review}

  @doc "Identify prune candidates without mutating any files."
  @spec prune_candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def prune_candidates(root, opts \\ [])

  def prune_candidates(root, opts) when is_binary(root) do
    _root = root
    category = Keyword.get(opts, :category)
    max_entries = Keyword.get(opts, :max_entries_per_category, 500)
    retention_policy = Keyword.get(opts, :retention_policy, "preserve_markdown")

    {:ok, entries} = Memory.list_entries(category: category, include_deleted?: false)

    entries
    |> Enum.group_by(& &1.category)
    |> Enum.flat_map(fn {_category, entries} ->
      entries
      |> prune_nominated_candidates()
      |> Kernel.++(trace_retention_candidates(entries, retention_policy))
      |> Kernel.++(over_limit_candidates(entries, max_entries))
    end)
    |> dedupe_candidates()
    |> then(&{:ok, &1})
  end

  def prune_candidates(_root, _opts), do: {:error, :invalid_memory_root}

  @spec normalize_status(atom() | String.t() | nil) ::
          {:ok, :kept | :flagged | :prune_nominated} | {:error, term()}
  def normalize_status(status) when status in @statuses, do: {:ok, status}

  def normalize_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> case do
      "kept" -> {:ok, :kept}
      "flagged" -> {:ok, :flagged}
      "prune_nominated" -> {:ok, :prune_nominated}
      other -> {:error, {:invalid_review_status, other}}
    end
  end

  def normalize_status(status), do: {:error, {:invalid_review_status, status}}

  def strip_review(content) do
    content
    |> String.split("\n#{@review_header}", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp review_section(content) do
    case String.split(content, "\n#{@review_header}", parts: 2) do
      [_prefix, section] -> section
      _other -> ""
    end
  end

  defp replace_review_section(content, status, reviewed_at, reviewed_by, note) do
    """
    #{strip_review(content)}

    #{@review_header}

    - Reviewed: #{reviewed_at}
    - Reviewed by: #{reviewed_by}
    - Status: #{status}
    - Correction note: #{note}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp metadata("", _key), do: nil

  defp metadata(content, key) do
    case Regex.run(~r/^- #{Regex.escape(key)}: *(.*)$/m, content) do
      [_, value] -> String.trim(value)
      _match -> nil
    end
  end

  defp parse_status("kept"), do: :kept
  defp parse_status("flagged"), do: :flagged
  defp parse_status("prune_nominated"), do: :prune_nominated
  defp parse_status(_status), do: :unreviewed

  defp nullable(nil), do: nil
  defp nullable(""), do: nil
  defp nullable(value), do: value

  defp default_reviewed_at(nil),
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp default_reviewed_at(""), do: default_reviewed_at(nil)
  defp default_reviewed_at(value), do: value

  defp default_string(nil, default), do: default
  defp default_string(value, _default) when is_binary(value), do: String.trim(value)
  defp default_string(value, _default), do: to_string(value)

  defp prune_nominated_candidates(entries) do
    entries
    |> Enum.filter(&(&1.review_status == :prune_nominated))
    |> Enum.map(&candidate(&1, :prune_nominated))
  end

  defp trace_retention_candidates(_entries, "preserve_markdown"), do: []

  defp trace_retention_candidates(entries, policy) do
    cutoff_days =
      case policy do
        "prune_traces_after_30d" -> 30
        "prune_traces_after_90d" -> 90
        _other -> nil
      end

    if cutoff_days do
      cutoff = DateTime.add(DateTime.utc_now(), -cutoff_days, :day)

      entries
      |> Enum.filter(&(&1.category == :traces and older_than?(&1, cutoff)))
      |> Enum.map(&candidate(&1, :trace_retention))
    else
      []
    end
  end

  defp over_limit_candidates(entries, max_entries) do
    entries
    |> Enum.sort_by(&{&1.timestamp, &1.path}, :desc)
    |> Enum.drop(max_entries)
    |> Enum.map(&candidate(&1, :category_over_limit))
  end

  defp older_than?(entry, cutoff) do
    case DateTime.from_iso8601(entry.timestamp) do
      {:ok, timestamp, _offset} -> DateTime.compare(timestamp, cutoff) == :lt
      _other -> false
    end
  end

  defp candidate(entry, reason) do
    %{
      path: entry.path,
      category: entry.category,
      summary: entry.summary,
      timestamp: entry.timestamp,
      review_status: entry.review_status,
      reason: reason
    }
  end

  defp dedupe_candidates(candidates) do
    candidates
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(&{&1.category, &1.timestamp, &1.path}, :desc)
  end
end
