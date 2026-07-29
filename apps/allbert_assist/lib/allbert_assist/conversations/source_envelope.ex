defmodule AllbertAssist.Conversations.SourceEnvelope do
  @moduledoc """
  Versioned conversation datum returned by `Conversations.Corpus`.

  This struct carries canonical content and verified origin evidence. It is
  data, not a grant or an authorization decision.
  """

  @enforce_keys [
    :source_type,
    :source_id,
    :thread_id,
    :operator_id,
    :user_id,
    :principal_digest,
    :role,
    :author,
    :trust,
    :origin_scope,
    :origin_overlays,
    :surface,
    :thread_kind,
    :content,
    :content_digest,
    :inserted_at,
    :source_version,
    :origin,
    :trace_refs
  ]

  defstruct schema_version: 1,
            source_type: :conversation,
            source_id: nil,
            thread_id: nil,
            operator_id: nil,
            user_id: nil,
            principal_digest: nil,
            role: nil,
            author: nil,
            trust: :private_operator,
            origin_scope: nil,
            origin_overlays: [],
            surface: nil,
            thread_kind: nil,
            content: nil,
            content_digest: nil,
            inserted_at: nil,
            source_version: 1,
            origin: nil,
            trace_refs: []

  @type origin :: %{
          thread_channel_ref_id: String.t(),
          owner_scope: String.t(),
          channel: String.t(),
          receiver_account_ref: String.t(),
          provider_thread_key: String.t(),
          origin_principal_digest: String.t(),
          principal_normalizer_version: String.t()
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          source_type: :conversation,
          source_id: String.t(),
          thread_id: String.t(),
          operator_id: String.t(),
          user_id: String.t(),
          principal_digest: String.t(),
          role: String.t(),
          author: :operator | :assistant,
          trust: :private_operator,
          origin_scope: :local_operator | :mapped_operator_dm,
          origin_overlays: [] | [:e2ee_operator],
          surface: String.t(),
          thread_kind: String.t(),
          content: String.t(),
          content_digest: String.t(),
          inserted_at: DateTime.t(),
          source_version: non_neg_integer(),
          origin: origin() | nil,
          trace_refs: [String.t()]
        }
end
