defmodule AllbertAssist.Memory.Entry do
  @moduledoc """
  Normalized in-memory representation of a markdown memory entry.
  """

  @enforce_keys [:path, :category, :timestamp, :summary, :body]
  defstruct [
    :path,
    :category,
    :timestamp,
    :source_signal_id,
    :actor,
    :agent,
    :channel,
    :app_id,
    :namespace,
    :kind,
    :idempotency_key,
    :source_ref,
    :summary,
    :body,
    review_status: :unreviewed,
    reviewed_at: nil,
    reviewed_by: nil,
    correction_note: nil
  ]

  @type review_status :: :unreviewed | :kept | :flagged | :prune_nominated

  @type t :: %__MODULE__{
          path: String.t(),
          category: atom(),
          timestamp: String.t(),
          source_signal_id: String.t() | nil,
          actor: String.t() | nil,
          agent: String.t() | nil,
          channel: String.t() | nil,
          app_id: String.t() | nil,
          namespace: String.t() | nil,
          kind: String.t() | nil,
          idempotency_key: String.t() | nil,
          source_ref: String.t() | nil,
          summary: String.t(),
          body: String.t(),
          review_status: review_status(),
          reviewed_at: String.t() | nil,
          reviewed_by: String.t() | nil,
          correction_note: String.t() | nil
        }

  @doc "Build a normalized entry struct from the historical memory map shape."
  @spec from_map(map()) :: t()
  def from_map(entry) when is_map(entry) do
    review = Map.get(entry, :review, %{})

    %__MODULE__{
      path: value(entry, :path, ""),
      category: category(Map.get(entry, :category, :notes)),
      timestamp: value(entry, :timestamp, ""),
      source_signal_id: value(entry, :source_signal_id, ""),
      actor: value(entry, :actor, "local"),
      agent: value(entry, :agent, ""),
      channel: value(entry, :channel, ""),
      app_id: nullable(value(entry, :app_id, "")),
      namespace: nullable(value(entry, :namespace, "")),
      kind: nullable(value(entry, :kind, "")),
      idempotency_key: nullable(value(entry, :idempotency_key, "")),
      source_ref: nullable(value(entry, :source_ref, "")),
      summary: value(entry, :summary, ""),
      body: value(entry, :body, ""),
      review_status:
        review_status(Map.get(entry, :review_status, Map.get(review, :review_status))),
      reviewed_at: nullable(value(entry, :reviewed_at, Map.get(review, :reviewed_at))),
      reviewed_by: nullable(value(entry, :reviewed_by, Map.get(review, :reviewed_by))),
      correction_note: nullable(value(entry, :correction_note, Map.get(review, :correction_note)))
    }
  end

  @doc "Return a map safe for action and CLI output."
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = entry, opts \\ []) do
    include_body? = Keyword.get(opts, :include_body, true)

    %{
      path: entry.path,
      category: entry.category,
      timestamp: entry.timestamp,
      source_signal_id: entry.source_signal_id,
      actor: entry.actor,
      agent: entry.agent,
      channel: entry.channel,
      app_id: entry.app_id,
      namespace: entry.namespace,
      kind: entry.kind,
      idempotency_key: entry.idempotency_key,
      source_ref: entry.source_ref,
      summary: entry.summary,
      review_status: entry.review_status,
      reviewed_at: entry.reviewed_at,
      reviewed_by: entry.reviewed_by,
      correction_note: entry.correction_note
    }
    |> maybe_put_body(entry.body, include_body?)
  end

  defp maybe_put_body(map, body, true), do: Map.put(map, :body, body)
  defp maybe_put_body(map, _body, false), do: map

  defp value(map, key, default) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp category(category) when is_atom(category), do: category

  defp category(category) when is_binary(category) do
    String.to_existing_atom(category)
  rescue
    ArgumentError -> :notes
  end

  defp category(_category), do: :notes

  defp review_status(status)
       when status in [:unreviewed, :kept, :flagged, :prune_nominated],
       do: status

  defp review_status(status) when is_binary(status) do
    case status do
      "kept" -> :kept
      "flagged" -> :flagged
      "prune_nominated" -> :prune_nominated
      _other -> :unreviewed
    end
  end

  defp review_status(_status), do: :unreviewed

  defp nullable(""), do: nil
  defp nullable(value), do: value
end
