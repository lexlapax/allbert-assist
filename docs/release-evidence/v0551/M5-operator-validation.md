# v0.55.1 M5 Operator Validation Evidence

Date: 2026-06-22

Base commit: `ceea0c09` (`v0.55b M4 evals and release gate`)

Raw transcript retained locally:
`docs/release-evidence/v0551/manual-v0551-20260622T070711Z.log`

Deterministic gate evidence retained locally:
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v0551/p0-13379/home/release_evidence/v0551/release-v0551-1782112068.json`

## Commands And Results

- S0 passed: `git status -sb` was clean on `main...origin/main`; `git tag --list
  v0.55.0` printed `v0.55.0`; manual home and evidence directory existed.
- S1 passed: `ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test
  release.v0551` exited 0. The gate ran migration, operator-console units,
  `:v0551` evals, and the channel-pack secret scan.
- S2 passed: `mix allbert.ecto.migrate --quiet` exited 0; settings readback
  showed `channels.tui.identity_map` mapped `default` to `local` and
  `channels.tui.enabled=true`.
- S3 passed: `mix allbert.channels show tui` reported channel `tui`, provider
  `terminal`, released, enabled, and one identity. `mix allbert.channels
  --parity` showed the `tui` row with `typed_command+list`, `rich`,
  `channels.tui.identity_map`, `turn_complete`, outbound `none`, released, live
  `true`.
- S4 passed: `mix allbert.plugins show allbert.notes_files` and `mix
  allbert.apps show notes_files` showed the trusted plugin/app with
  `write_note`; settings readback showed `apps.notes_files.notes_root` under
  `<ALLBERT_HOME>` and `permissions.notes_file_write="needs_confirmation"`.
- S5 launched one transcript-captured `mix allbert.tui` session at
  `allbert:default>`.

## In-Session Checks

- B1 passed: `/events` showed no rows before `/help`; `/help` rendered exactly
  `/status`, `/confirmations`, `/events`, `/channels`, `/settings get`, and
  `/help`; the after `/events` check still showed no rows.
- B2 passed: `/status` reported `node=nonode@nohost`, `beam_os_pid=36590`,
  `Channels.Supervisor: running child_count=8`, and the mapped `local` operator.
  `/channels` reported TUI enabled with one identity and redacted sibling-channel
  credential status. `/events` and `/confirmations` were empty before the normal
  turn. `/settings get channels.tui.identity_map` returned the bounded,
  non-sensitive identity map.
- B3 passed with nuance: the natural-language prompt `what are my recent channel
  events and confirmations?` went through the normal runtime path and did not
  render the `/events`, `/confirmations`, or `/status` operator report shapes. It
  produced a normal model-routed channel summary. The explicit `/events` command
  beside it rendered the operator event report and showed one normal inbound TUI
  event.
- B4 passed: `create a note titled v0551 with body warm console check` produced
  pending confirmation `conf_1782112771000000_17666` for `write_note`. The typed
  in-session approval `ALLBERT:APPROVE:conf_1782112771000000_17666` returned
  `Confirmation conf_1782112771000000_17666 is approved.` After approval,
  `/status` still reported `beam_os_pid=36590` with increased uptime,
  `/confirmations` showed the confirmation approved, and `/events` showed three
  rows including the normal inbound turn and the callback approval row.

## Post-Session Checks

- `/quit` exited the TUI cleanly.
- `test -s "$V0551_TRANSCRIPT"` printed the transcript path.
- `rg -n '/help|/status|/channels|/events|/confirmations|/settings
  get|ALLBERT:APPROVE' "$V0551_TRANSCRIPT"` found the required commands and typed
  approval.

Result: M5 passed. The warm TUI session stayed in one BEAM (`beam_os_pid=36590`)
from B2 through B4, slash commands stayed read-only inspection paths, and the
write-note approval flow completed through the typed TUI callback without a cold
Mix command between in-session checks.
