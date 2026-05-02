---
name: plan-shell-command
description: Draft a shell command plan or safety note without executing any command. Use when the user asks to run, execute, or reason about a terminal command.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in plan_shell_command action.
allowed-tools: allbert:action:plan_shell_command
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: plan_shell_command
  allbert.permissions: command_plan
  allbert.confirmation: not_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_requested_permission
---

## Workflow

1. Identify the requested command or command-like intent.
2. Explain the plan, risk, and why command execution is not available in this milestone.
3. Never execute the command.
4. Keep destructive commands denied even when planning is allowed.
