
## 2026-05-02T12:00:00Z conf_golden_shell

- event: requested
- status: pending
- target_action: run_shell_command
- target_permission: shell_command
- origin_actor: alice
- origin_channel: cli
- resolver_actor: none
- resolver_channel: none
- resolver_surface: none
- same_channel: none
- resolution_reason: none
- decision_source: none
- source_trace_id: trace-shell
- target_command: mix test
- target_cwd: /tmp/allbert
- target_sandbox: level 1
- target_timeout: 1000ms
- target_output_cap: 4096 bytes
- audit_version: 1

## 2026-05-02T12:01:00Z conf_golden_shell

- event: approved
- status: approved
- target_action: run_shell_command
- target_permission: shell_command
- origin_actor: alice
- origin_channel: cli
- resolver_actor: alice
- resolver_channel: cli
- resolver_surface: mix allbert.confirmations approve
- same_channel: true
- resolution_reason: approved golden shell
- decision_source: operator
- source_trace_id: trace-shell
- target_command: mix test
- target_cwd: /tmp/allbert
- target_sandbox: level 1
- target_timeout: 1000ms
- target_output_cap: 4096 bytes
- target_result: completed
- target_exit: 0
- target_output_bytes: 12
- target_output_preview: ok
- audit_version: 1
