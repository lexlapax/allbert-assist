#!/usr/bin/env bash
# ARCHIVED v1.3 attended-validation script. Extracted from
# docs/plans/v1.3-request-flow.md so the operator invoked one line
# instead of pasting hundreds. The v1.3 FOV run it belongs to completed
# and passed on 2026-08-02; this file is provenance, not a live fixture.
#
# It is no longer executed by any test and no longer verified against the
# current schema, renderer, or CLI, so treat it as a record of what was
# run rather than as something that still runs. Release-specific
# validation scripts are not permanent repository fixtures.
if mix allbert admin models use-direct-answer direct_answer_local &&
   mix allbert admin settings set intent.model_assist_enabled true &&
   mix allbert admin settings set intent.direct_answer_model_enabled true &&
   mix allbert admin settings set objectives.fanout.enabled true &&
   mix allbert admin settings set objectives.fanout.rollout_mode automatic &&
   mix allbert admin settings get model_preferences.tasks.direct_answer | tee "$FOV_ROOT/direct-answer.txt" &&
   grep -Fq 'model_preferences.tasks.direct_answer=["direct_answer_local"]' "$FOV_ROOT/direct-answer.txt" &&
   mix allbert admin settings get model_preferences.tasks.fanout_manager | tee "$FOV_ROOT/fanout-manager.txt" &&
   grep -Fq 'model_preferences.tasks.fanout_manager=["direct_answer_local"]' "$FOV_ROOT/fanout-manager.txt" &&
   mix allbert admin settings get model_preferences.tasks.fanout_synthesis | tee "$FOV_ROOT/fanout-synthesis.txt" &&
   grep -Fq 'model_preferences.tasks.fanout_synthesis=["direct_answer_local"]' "$FOV_ROOT/fanout-synthesis.txt" &&
   mix allbert admin settings get objectives.fanout.max_model_calls_per_plan | tee "$FOV_ROOT/fanout-call-budget.txt" &&
   grep -Fq 'objectives.fanout.max_model_calls_per_plan=64' "$FOV_ROOT/fanout-call-budget.txt" &&
   mix allbert admin settings get objectives.fanout.max_output_tokens_per_plan | tee "$FOV_ROOT/fanout-token-budget.txt" &&
   grep -Fq 'objectives.fanout.max_output_tokens_per_plan=32768' "$FOV_ROOT/fanout-token-budget.txt" &&
   mix allbert.settings model-doctor | tee "$FOV_ROOT/model-doctor.txt" &&
   grep -Fq 'fanout_manager status=ok chain=[direct_answer_local] resolved=direct_answer_local(qwen2.5:7b) unavailable-role=none auto-pull=false key=model_preferences.tasks.fanout_manager' "$FOV_ROOT/model-doctor.txt" &&
   grep -Fq 'fanout_synthesis status=ok chain=[direct_answer_local] resolved=direct_answer_local(qwen2.5:7b) unavailable-role=none auto-pull=false key=model_preferences.tasks.fanout_synthesis' "$FOV_ROOT/model-doctor.txt" &&
   mix allbert admin models doctor direct_answer_local | tee "$FOV_ROOT/doctor.txt" &&
   grep -q '^endpoint_ok=true$' "$FOV_ROOT/doctor.txt" &&
   grep -q '^model_available=true$' "$FOV_ROOT/doctor.txt" &&
   grep -q '^redacted_host=localhost$' "$FOV_ROOT/doctor.txt"
then
  echo 'PASS FOV-1: real manager, child generator, and composer path is available'
else
  echo 'FAIL FOV-1: stop; keep this shell and close through FOV-8'
fi
