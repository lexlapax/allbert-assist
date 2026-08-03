#!/usr/bin/env bash
# Extracted from docs/plans/v1.3-request-flow.md. Checked in so the
# operator invokes one line instead of pasting hundreds, and so
# test/fov_scripts_test.exs can execute checks against it.
# v1.3-SCOPED. Archive with the v1.3 plan at closeout; do not carry
# forward. Release-specific validation scripts are not permanent
# repository fixtures.
fov_7r_validate() {
  FOV_MAIN_DB="$ALLBERT_HOME/db/allbert.sqlite3"
  FOV_SEARCH_DB="$ALLBERT_HOME/projections/search/current.sqlite3"
  test -f "$FOV_MAIN_DB" || return 1
  test -f "$FOV_SEARCH_DB" || return 1

  sqlite3 -readonly -noheader "$FOV_MAIN_DB" \
    'PRAGMA integrity_check;' \
    > "$FOV_ROOT/main-db-integrity.txt" || return 1
  sqlite3 -readonly -noheader "$FOV_SEARCH_DB" \
    'PRAGMA integrity_check;' \
    > "$FOV_ROOT/search-db-integrity.txt" || return 1

  sqlite3 -readonly -noheader "$FOV_MAIN_DB" \
    'PRAGMA foreign_key_check;' \
    > "$FOV_ROOT/main-db-foreign-keys.txt" || return 1
  sqlite3 -readonly -noheader "$FOV_SEARCH_DB" \
    'PRAGMA foreign_key_check;' \
    > "$FOV_ROOT/search-db-foreign-keys.txt" || return 1

  test ! -s "$FOV_ROOT/main-db-foreign-keys.txt" || return 1
  test ! -s "$FOV_ROOT/search-db-foreign-keys.txt" || return 1
  printf '0|0\n' > "$FOV_ROOT/db-foreign-key-counts.txt" || return 1

  sqlite3 -readonly -noheader -separator '|' "$FOV_MAIN_DB" \
    "WITH parent AS (
       SELECT * FROM objectives
       WHERE fanout_role='parent'
       ORDER BY inserted_at DESC,id DESC LIMIT 1
     ), children AS (
       SELECT c.* FROM objectives AS c
       JOIN parent AS p ON c.parent_objective_id=p.id
       WHERE c.fanout_role='child'
     )
     SELECT
       (SELECT count(*) FROM objectives WHERE fanout_role='parent'),
       count(*),
       count(DISTINCT c.queue_position),
       min(c.queue_position),
       max(c.queue_position),
       sum(c.status='completed'),
       sum(c.run_attempt_count=1),
       p.status,
       p.join_policy,
       p.join_outcome,
       p.kickoff_delivery_state,
       p.report_composition_state,
       p.report_source,
       p.report_delivery_state
     FROM parent AS p JOIN children AS c;" \
    > "$FOV_ROOT/durable-fanout-topology.txt" || return 1

  sqlite3 -readonly -noheader -separator '|' "$FOV_MAIN_DB" \
    "WITH parent AS (
       SELECT * FROM objectives
       WHERE fanout_role='parent'
       ORDER BY inserted_at DESC,id DESC LIMIT 1
     ), proposal AS (
       SELECT e.payload
       FROM objective_events AS e
       JOIN parent AS p ON p.id=e.objective_id
       WHERE e.kind='fanout_proposed'
       ORDER BY e.rowid DESC LIMIT 1
     )
     SELECT
       json_extract(p.proposer_hint,'$.fanout_plan.budget.version'),
       json_extract(p.proposer_hint,'$.fanout_plan.budget.configured_model_calls'),
       json_extract(p.proposer_hint,'$.fanout_plan.budget.required_model_calls'),
       json_extract(p.proposer_hint,'$.fanout_plan.budget.configured_output_tokens'),
       json_extract(p.proposer_hint,'$.fanout_plan.budget.required_output_tokens'),
       json_extract(p.proposer_hint,'$.fanout_plan.budget.max_elapsed_ms'),
       CASE WHEN
         json_type(p.proposer_hint,'$.fanout_plan.budget.version')='integer' AND
         json_type(p.proposer_hint,'$.fanout_plan.budget.configured_model_calls')='integer' AND
         json_type(p.proposer_hint,'$.fanout_plan.budget.required_model_calls')='integer' AND
         json_type(p.proposer_hint,'$.fanout_plan.budget.configured_output_tokens')='integer' AND
         json_type(p.proposer_hint,'$.fanout_plan.budget.required_output_tokens')='integer' AND
         json_type(p.proposer_hint,'$.fanout_plan.budget.max_elapsed_ms')='integer' AND
         json_extract(e.payload,'$.budget.version')=
           json_extract(p.proposer_hint,'$.fanout_plan.budget.version') AND
         json_extract(e.payload,'$.budget.configured_model_calls')=
           json_extract(p.proposer_hint,'$.fanout_plan.budget.configured_model_calls') AND
         json_extract(e.payload,'$.budget.required_model_calls')=
           json_extract(p.proposer_hint,'$.fanout_plan.budget.required_model_calls') AND
         json_extract(e.payload,'$.budget.configured_output_tokens')=
           json_extract(p.proposer_hint,'$.fanout_plan.budget.configured_output_tokens') AND
         json_extract(e.payload,'$.budget.required_output_tokens')=
           json_extract(p.proposer_hint,'$.fanout_plan.budget.required_output_tokens') AND
         json_extract(e.payload,'$.budget.max_elapsed_ms')=
           json_extract(p.proposer_hint,'$.fanout_plan.budget.max_elapsed_ms')
            THEN 1 ELSE 0 END
     FROM parent AS p CROSS JOIN proposal AS e;" \
    > "$FOV_ROOT/durable-budget-types.txt" || return 1

  sqlite3 -readonly -noheader -separator '|' "$FOV_MAIN_DB" \
    "WITH parent AS (
       SELECT * FROM objectives
       WHERE fanout_role='parent'
       ORDER BY inserted_at DESC,id DESC LIMIT 1
     ), children AS (
       SELECT c.id FROM objectives AS c
       JOIN parent AS p ON c.parent_objective_id=p.id
       WHERE c.fanout_role='child'
     ), receipts AS (
       SELECT e.payload
       FROM objective_events AS e
       JOIN children AS c ON c.id=e.objective_id
       WHERE e.kind='run_completed'
     )
     SELECT
       count(*),
       sum(json_extract(payload,'$.quality_receipt.version')=3),
       sum(json_extract(payload,
             '$.quality_receipt.rule_catalog_version')=2),
       sum(length(json_extract(payload,
             '$.quality_receipt.generator_config_sha256'))=64 AND
           json_extract(payload,'$.quality_receipt.generator_config_sha256')
             NOT GLOB '*[^0-9a-f]*'),
       sum(json_extract(payload,'$.quality_receipt.generation_call_count')=1 AND
           json_extract(payload,'$.quality_receipt.provider_call_count')=1),
       sum(length(json_extract(payload,
             '$.quality_receipt.objective_id_sha256'))=64 AND
           json_extract(payload,'$.quality_receipt.objective_id_sha256')
             NOT GLOB '*[^0-9a-f]*' AND
           length(json_extract(payload,
             '$.quality_receipt.step_id_sha256'))=64 AND
           json_extract(payload,'$.quality_receipt.step_id_sha256')
             NOT GLOB '*[^0-9a-f]*'),
       sum(length(json_extract(payload,
             '$.quality_receipt.task_contract_sha256'))=64 AND
           json_extract(payload,'$.quality_receipt.task_contract_sha256')
             NOT GLOB '*[^0-9a-f]*' AND
           length(json_extract(payload,
             '$.quality_receipt.final_answer_sha256'))=64 AND
           json_extract(payload,'$.quality_receipt.final_answer_sha256')
             NOT GLOB '*[^0-9a-f]*'),
       sum(json_extract(payload,'$.quality_receipt.verdict')='accepted')
     FROM receipts;" \
    > "$FOV_ROOT/worker-quality-receipts.txt" || return 1

  sqlite3 -readonly -noheader -separator '|' "$FOV_MAIN_DB" \
    "WITH parent AS (
       SELECT * FROM objectives
       WHERE fanout_role='parent'
       ORDER BY inserted_at DESC,id DESC LIMIT 1
     ), child AS (
       SELECT c.*,
              coalesce(c.last_observation_summary,c.progress_summary,'') AS detail,
              CASE WHEN instr(coalesce(c.last_observation_summary,c.progress_summary,''),char(10))>0
                   THEN substr(coalesce(c.last_observation_summary,c.progress_summary,''),1,
                          instr(coalesce(c.last_observation_summary,c.progress_summary,''),char(10))-1)
                   ELSE coalesce(c.last_observation_summary,c.progress_summary,'') END AS first_line
       FROM objectives AS c
       JOIN parent AS p ON c.parent_objective_id=p.id
       WHERE c.fanout_role='child'
     )
     SELECT
       p.report_composition_state,
       p.report_source,
       p.report_delivery_state,
       count(c.id),
       sum(CASE WHEN c.status='completed' THEN 1 ELSE 0 END),
       sum(CASE WHEN c.first_line <> '' AND instr(p.report_body,c.first_line)>0
                THEN 1 ELSE 0 END),
       sum(CASE WHEN c.first_line <> '' AND
                     ((length(p.report_body)-length(replace(p.report_body,c.first_line,''))) /
                       NULLIF(length(c.first_line),0))=1
                THEN 1 ELSE 0 END),
       CASE WHEN length(CAST(p.report_body AS BLOB)) <= 32768 THEN 1 ELSE 0 END,
       CASE WHEN NOT EXISTS (
         SELECT 1
         FROM child AS earlier
         JOIN child AS later ON earlier.queue_position<later.queue_position
         WHERE earlier.first_line='' OR later.first_line='' OR
               instr(p.report_body,earlier.first_line)=0 OR
               instr(p.report_body,later.first_line)=0 OR
               instr(p.report_body,earlier.first_line)>=instr(p.report_body,later.first_line)
       ) THEN 1 ELSE 0 END
     FROM parent AS p JOIN child AS c;" \
    > "$FOV_ROOT/durable-report-state.txt" || return 1

  sqlite3 -readonly -noheader -separator '|' "$FOV_MAIN_DB" \
    "WITH parent AS (
       SELECT * FROM objectives
       WHERE fanout_role='parent'
       ORDER BY inserted_at DESC,id DESC LIMIT 1
     ), facts AS (
       SELECT d.value AS fact
       FROM conversation_messages AS m
       JOIN parent AS p ON m.thread_id=p.source_thread_id
       JOIN json_each(m.action_log,'$.diagnostics') AS d
       WHERE m.role='assistant'
     ), rendered AS (
       SELECT 1 AS ordinal,
              printf('%s|%s|%s|%s|%d|%d|%d',
                json_extract(fact,'$.result'),
                json_extract(fact,'$.outcome'),
                json_extract(fact,'$.policy_outcome'),
                json_extract(fact,'$.join_role'),
                json_extract(fact,'$.attempts'),
                json_extract(fact,'$.work_unit_count'),
                json_extract(fact,'$.reviewed')) AS value
       FROM facts
       WHERE json_extract(fact,'$.source')='fanout_manager'
       UNION ALL
       SELECT 2,json_extract(fact,'$.outcome')
       FROM facts
       WHERE json_extract(fact,'$.source')='fanout_admission'
     )
     SELECT value FROM rendered ORDER BY ordinal;" \
    > "$FOV_ROOT/manager-admission.txt" || return 1

  sqlite3 -readonly -noheader -separator '|' "$FOV_MAIN_DB" \
    "WITH parent AS (
       SELECT * FROM objectives
       WHERE fanout_role='parent'
       ORDER BY inserted_at DESC,id DESC LIMIT 1
     ), selected AS (
       SELECT e.payload
       FROM objective_events AS e
       JOIN parent AS p ON e.objective_id=p.id
       WHERE e.kind='fanout_report_selected'
       ORDER BY e.rowid DESC LIMIT 1
     )
     SELECT
       (SELECT count(*) FROM objective_events AS e
          JOIN parent AS p2 ON e.objective_id=p2.id
          WHERE e.kind='fanout_report_selected'),
       json_extract(s.payload,'$.source'),
       json_extract(s.payload,'$.layout_version'),
       json_extract(s.payload,'$.validation_outcome'),
       json_extract(s.payload,'$.synthesis_contract_version'),
       CASE WHEN json_extract(s.payload,'$.generation_call_count')=1 AND
                      json_extract(s.payload,'$.provider_call_count')=1
            THEN 1 ELSE 0 END,
       json_array_length(json_extract(s.payload,'$.sections')),
       json_extract(s.payload,'$.sections[0].relationship'),
       json(json_extract(s.payload,'$.sections[0].ordered_queue_positions')),
       json(json_extract(s.payload,'$.covered_queue_positions')),
       CASE WHEN length(json_extract(s.payload,'$.synthesis_sha256'))=64
            THEN 1 ELSE 0 END
     FROM parent AS p CROSS JOIN selected AS s;" \
    > "$FOV_ROOT/report-selection.txt" || return 1

  FOV_REPORT_BODY_SHA="$(
    sqlite3 -readonly -noheader "$FOV_MAIN_DB" \
      "WITH parent AS (
         SELECT * FROM objectives
         WHERE fanout_role='parent'
         ORDER BY inserted_at DESC,id DESC LIMIT 1
       )
       SELECT hex(CAST(report_body AS BLOB)) FROM parent;" |
      xxd -r -p |
      shasum -a 256 |
      awk '{print $1}'
  )" || return 1

  FOV_EVENT_BODY_SHA="$(
    sqlite3 -readonly -noheader "$FOV_MAIN_DB" \
      "WITH parent AS (
         SELECT * FROM objectives
         WHERE fanout_role='parent'
         ORDER BY inserted_at DESC,id DESC LIMIT 1
       )
       SELECT json_extract(e.payload,'$.body_sha256')
       FROM objective_events AS e
       JOIN parent AS p ON e.objective_id=p.id
       WHERE e.kind='fanout_report_selected';"
  )" || return 1

  if [[ "$FOV_REPORT_BODY_SHA" =~ ^[0-9a-f]{64}$ ]] &&
     [[ "$FOV_EVENT_BODY_SHA" =~ ^[0-9a-f]{64}$ ]] &&
     test "$FOV_REPORT_BODY_SHA" = "$FOV_EVENT_BODY_SHA"
  then
    printf '1\n' > "$FOV_ROOT/durable-report-body-binding.txt" || return 1
  else
    printf '0\n' > "$FOV_ROOT/durable-report-body-binding.txt" || return 1
  fi

  FOV_SYNTHESIS_HEX="$(
    sqlite3 -readonly -noheader "$FOV_MAIN_DB" \
      "WITH parent AS (
         SELECT report_body FROM objectives
         WHERE fanout_role='parent'
         ORDER BY inserted_at DESC,id DESC LIMIT 1
       ), bounds AS (
         SELECT report_body,
                'Model-authored advisory synthesis:' || char(10) || char(10) ||
                  '> ' AS prefix,
                char(10) || char(10) ||
                  'Effect verification comes only from the authoritative child-results appendix below.'
                  AS suffix
         FROM parent
       ), located AS (
         SELECT report_body,prefix,suffix,
                instr(report_body,prefix)+length(prefix) AS first_byte,
                instr(report_body,suffix) AS suffix_byte
         FROM bounds
       )
       SELECT CASE WHEN first_byte>length(prefix) AND suffix_byte>first_byte
                   THEN hex(CAST(substr(report_body,first_byte,
                                        suffix_byte-first_byte) AS BLOB))
                   ELSE '' END
       FROM located;"
  )" || return 1
  FOV_EVENT_SYNTHESIS_SHA="$(
    sqlite3 -readonly -noheader "$FOV_MAIN_DB" \
      "WITH parent AS (
         SELECT * FROM objectives
         WHERE fanout_role='parent'
         ORDER BY inserted_at DESC,id DESC LIMIT 1
       )
       SELECT json_extract(e.payload,'$.synthesis_sha256')
       FROM objective_events AS e
       JOIN parent AS p ON e.objective_id=p.id
       WHERE e.kind='fanout_report_selected';"
  )" || return 1

  if [[ "$FOV_SYNTHESIS_HEX" =~ ^([0-9A-F][0-9A-F])+$ ]]; then
    FOV_SYNTHESIS_SHA="$(
      printf '%s' "$FOV_SYNTHESIS_HEX" |
        xxd -r -p |
        shasum -a 256 |
        awk '{print $1}'
    )" || return 1
  else
    FOV_SYNTHESIS_SHA=
  fi
  if [[ "$FOV_SYNTHESIS_SHA" =~ ^[0-9a-f]{64}$ ]] &&
     [[ "$FOV_EVENT_SYNTHESIS_SHA" =~ ^[0-9a-f]{64}$ ]] &&
     test "$FOV_SYNTHESIS_SHA" = "$FOV_EVENT_SYNTHESIS_SHA"
  then
    printf '1\n' > "$FOV_ROOT/durable-synthesis-binding.txt" || return 1
  else
    printf '0\n' > "$FOV_ROOT/durable-synthesis-binding.txt" || return 1
  fi

  cat "$FOV_ROOT/main-db-integrity.txt" || return 1
  cat "$FOV_ROOT/search-db-integrity.txt" || return 1
  cat "$FOV_ROOT/db-foreign-key-counts.txt" || return 1
  cat "$FOV_ROOT/durable-fanout-topology.txt" || return 1
  cat "$FOV_ROOT/durable-budget-types.txt" || return 1
  cat "$FOV_ROOT/worker-quality-receipts.txt" || return 1
  cat "$FOV_ROOT/durable-report-state.txt" || return 1
  cat "$FOV_ROOT/manager-admission.txt" || return 1
  cat "$FOV_ROOT/report-selection.txt" || return 1
  cat "$FOV_ROOT/durable-report-body-binding.txt" || return 1
  cat "$FOV_ROOT/durable-synthesis-binding.txt" || return 1

  test "$(cat "$FOV_ROOT/main-db-integrity.txt")" = 'ok' || return 1
  test "$(cat "$FOV_ROOT/search-db-integrity.txt")" = 'ok' || return 1
  test "$(cat "$FOV_ROOT/db-foreign-key-counts.txt")" = '0|0' || return 1
  test "$(cat "$FOV_ROOT/durable-fanout-topology.txt")" = \
    '1|2|2|0|1|2|2|completed|all_terminal|success|acknowledged|ready|model|delivered' || return 1
  test "$(cat "$FOV_ROOT/durable-budget-types.txt")" = \
    '3|64|4|32768|11264|300000|1' || return 1
  test "$(cat "$FOV_ROOT/worker-quality-receipts.txt")" = \
    '2|2|2|2|2|2|2|2' || return 1
  test "$(cat "$FOV_ROOT/durable-report-state.txt")" = \
    'ready|model|delivered|2|2|2|2|1|1' || return 1
  test "$(cat "$FOV_ROOT/manager-admission.txt")" = \
    "$(printf '%s\n%s' \
      'fanout|planned|independent_advisory|parent_presentation_only|1|2|1' \
      'admitted')" || return 1
  test "$(cat "$FOV_ROOT/report-selection.txt")" = \
    '1|model|2|accepted|3|1|1|complementary|[0,1]|[0,1]|1' || return 1
  test "$(cat "$FOV_ROOT/durable-report-body-binding.txt")" = '1' || return 1
  test "$(cat "$FOV_ROOT/durable-synthesis-binding.txt")" = '1' || return 1
}

if fov_7r_validate; then
  echo 'PASS FOV-7R: typed durable budgets authorized one complete model-composed two-child report'
else
  echo 'FAIL FOV-7R: stop; retain this Home and close through FOV-8'
fi
unset -f fov_7r_validate
