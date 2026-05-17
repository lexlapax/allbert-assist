
## 2026-05-02T12:00:00Z conf_golden_skill

- event: requested
- status: pending
- target_action: run_skill_script
- target_permission: skill_script
- origin_actor: alice
- origin_channel: cli
- resolver_actor: none
- resolver_channel: none
- resolver_surface: none
- same_channel: none
- resolution_reason: none
- decision_source: none
- source_trace_id: trace-skill
- target_skill: reporter
- target_script: scripts/report.exs
- target_digest: abc123
- target_cwd: /tmp/allbert
- target_sandbox: level 1
- target_timeout: 2000ms
- target_output_cap: 2048 bytes
- target_env: ALLBERT_HOME
- audit_version: 1

## 2026-05-02T12:01:01Z conf_golden_skill

- event: expired
- status: expired
- target_action: run_skill_script
- target_permission: skill_script
- origin_actor: alice
- origin_channel: cli
- resolver_actor: system
- resolver_channel: scheduler
- resolver_surface: expiry sweep
- same_channel: false
- resolution_reason: ttl elapsed
- decision_source: system_ttl
- source_trace_id: trace-skill
- target_skill: reporter
- target_script: scripts/report.exs
- target_digest: abc123
- target_cwd: /tmp/allbert
- target_sandbox: level 1
- target_timeout: 2000ms
- target_output_cap: 2048 bytes
- target_env: ALLBERT_HOME
- audit_version: 1
