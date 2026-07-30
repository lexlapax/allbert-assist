defmodule AllbertAssist.Search.Page do
  @moduledoc "Typed, surface-neutral page returned by conversation Search Central."

  @enforce_keys [
    :results,
    :generation_id,
    :projection_revision,
    :indexed_through,
    :freshness_ms,
    :scanned_count,
    :filtered_count,
    :incomplete
  ]
  defstruct results: [],
            next_cursor: nil,
            generation_id: nil,
            projection_revision: 0,
            indexed_through: nil,
            freshness_ms: nil,
            scanned_count: 0,
            filtered_count: 0,
            incomplete: false,
            incomplete_reason: nil

  @type t :: %__MODULE__{}
end
