
## 2026-05-02T12:00:00Z conf_golden_package

- event: requested
- status: pending
- target_action: run_package_install
- target_permission: package_install
- origin_actor: alice
- origin_channel: cli
- resolver_actor: none
- resolver_channel: none
- resolver_surface: none
- same_channel: none
- resolution_reason: none
- decision_source: none
- source_trace_id: trace-package
- target_manager: mix
- target_packages: req, nx
- target_target_root: /tmp/allbert
- target_dry_run_argv: mix deps.get --dry-run
- target_execution_argv: mix deps.get
- target_timeout: 5000ms
- target_output_cap: 8192 bytes
- audit_version: 1

## 2026-05-02T12:01:00Z conf_golden_package

- event: denied
- status: denied
- target_action: run_package_install
- target_permission: package_install
- origin_actor: alice
- origin_channel: cli
- resolver_actor: alice
- resolver_channel: liveview
- resolver_surface: /settings
- same_channel: false
- resolution_reason: package not needed
- decision_source: operator
- source_trace_id: trace-package
- target_manager: mix
- target_packages: req, nx
- target_target_root: /tmp/allbert
- target_dry_run_argv: mix deps.get --dry-run
- target_execution_argv: mix deps.get
- target_timeout: 5000ms
- target_output_cap: 8192 bytes
- audit_version: 1
