defmodule AllbertAssist.Search.Result do
  @moduledoc "One currently authorized conversation-search result."

  @enforce_keys [
    :source_id,
    :thread_id,
    :author,
    :trust,
    :surface,
    :thread_kind,
    :timestamp,
    :snippet,
    :score,
    :generation_id,
    :projection_revision
  ]
  defstruct schema_version: 1,
            source_type: :conversation,
            source_id: nil,
            thread_id: nil,
            author: nil,
            trust: nil,
            surface: nil,
            thread_kind: nil,
            timestamp: nil,
            snippet: nil,
            score: nil,
            generation_id: nil,
            projection_revision: nil

  @type t :: %__MODULE__{}
end
