
## 2026-05-02T12:00:00Z conf_golden_resource

- event: requested
- status: pending
- target_action: direct_answer
- target_permission: read_only
- origin_actor: alice
- origin_channel: cli
- resolver_actor: none
- resolver_channel: none
- resolver_surface: none
- same_channel: none
- resolution_reason: none
- decision_source: none
- source_trace_id: trace-resource
- target_resource_prompt_context_url_summary_read_exact_url: https://example.com/page consumer=intent
- audit_version: 1

## 2026-05-02T12:01:00Z conf_golden_resource

- event: cancelled
- status: cancelled
- target_action: direct_answer
- target_permission: read_only
- origin_actor: alice
- origin_channel: cli
- resolver_actor: alice
- resolver_channel: cli
- resolver_surface: mix allbert.confirmations cancel
- same_channel: true
- resolution_reason: operator cancelled
- decision_source: operator
- source_trace_id: trace-resource
- target_resource_prompt_context_url_summary_read_exact_url: https://example.com/page consumer=intent
- audit_version: 1
