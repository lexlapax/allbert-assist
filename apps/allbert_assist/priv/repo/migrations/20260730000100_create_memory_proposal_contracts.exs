defmodule AllbertAssist.Repo.Migrations.CreateMemoryProposalContracts do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE memory_proposals (
        id TEXT PRIMARY KEY NOT NULL,
        operator_id TEXT NOT NULL,
        namespace TEXT NOT NULL DEFAULT 'default',
        category TEXT NOT NULL,
        kind TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        classification TEXT NOT NULL,
        proposed_claim TEXT,
        span_provenance TEXT,
        source_evidence TEXT NOT NULL,
        proposal_digest TEXT NOT NULL,
        source_digest TEXT NOT NULL,
        principal_digest TEXT NOT NULL,
        origin_scope TEXT NOT NULL,
        extractor_profile TEXT NOT NULL,
        extractor_version INTEGER NOT NULL,
        run_id TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 1,
        idempotency_key TEXT NOT NULL,
        applying_transition_id TEXT,
        applying_decision_digest TEXT,
        applying_payload TEXT,
        result TEXT NOT NULL DEFAULT '{}',
        reviewed_by TEXT,
        reviewed_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT memory_proposals_kind_check
          CHECK (kind IN ('ordinary', 'protected_stub')),
        CONSTRAINT memory_proposals_status_check
          CHECK (status IN ('pending', 'applying', 'kept', 'rejected', 'stale', 'forgotten', 'error')),
        CONSTRAINT memory_proposals_protected_stub_content_check
          CHECK (kind != 'protected_stub' OR
            (proposed_claim IS NULL AND span_provenance IS NULL AND applying_payload IS NULL)),
        CONSTRAINT memory_proposals_ordinary_content_check
          CHECK (kind != 'ordinary' OR
            (proposed_claim IS NOT NULL AND span_provenance IS NOT NULL))
      )
      """,
      "DROP TABLE memory_proposals"
    )

    create unique_index(:memory_proposals, [:operator_id, :namespace, :idempotency_key],
             name: :memory_proposals_idempotency_uidx
           )

    create index(:memory_proposals, [:operator_id, :namespace, :status],
             name: :memory_proposals_review_queue_idx
           )

    create index(:memory_proposals, [:operator_id, :source_digest],
             name: :memory_proposals_source_digest_idx
           )

    execute(
      """
      CREATE TABLE memory_proposal_batches (
        id TEXT PRIMARY KEY NOT NULL,
        operator_id TEXT NOT NULL,
        namespace TEXT NOT NULL DEFAULT 'default',
        status TEXT NOT NULL DEFAULT 'pending',
        bindings TEXT NOT NULL,
        results TEXT NOT NULL DEFAULT '{}',
        requested_by TEXT NOT NULL,
        completed_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        CONSTRAINT memory_proposal_batches_status_check
          CHECK (status IN ('pending', 'applying', 'complete', 'forgotten', 'error'))
      )
      """,
      "DROP TABLE memory_proposal_batches"
    )

    create index(:memory_proposal_batches, [:operator_id, :namespace, :status],
             name: :memory_proposal_batches_status_idx
           )

    execute(
      """
      CREATE TABLE memory_proposal_suppressions (
        id TEXT PRIMARY KEY NOT NULL,
        operator_id TEXT NOT NULL,
        namespace TEXT NOT NULL DEFAULT 'default',
        proposal_digest TEXT NOT NULL,
        source_digest TEXT NOT NULL,
        normalizer_version INTEGER NOT NULL,
        reason TEXT NOT NULL,
        inserted_at TEXT NOT NULL,
        CONSTRAINT memory_proposal_suppressions_reason_check
          CHECK (reason IN ('operator_rejected', 'forgotten'))
      )
      """,
      "DROP TABLE memory_proposal_suppressions"
    )

    create unique_index(
             :memory_proposal_suppressions,
             [:operator_id, :namespace, :proposal_digest, :source_digest, :normalizer_version],
             name: :memory_proposal_suppressions_exact_uidx
           )
  end
end
