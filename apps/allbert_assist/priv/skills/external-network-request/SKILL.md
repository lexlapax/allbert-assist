---
name: external-network-request
description: Recognize external network requests and require future confirmation without making a call. Use when the user asks Allbert to fetch, browse, download, call an API, or use the internet.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in external_network_request action.
allowed-tools: allbert:action:external_network_request
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: external_network_request
  allbert.permissions: external_network
  allbert.confirmation: future_confirmation_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_confirmation_requirement
---

## Workflow

1. Recognize that the user requested external network access.
2. Explain that v0.03 does not make network calls from skill declarations.
3. Return the future confirmation requirement without browsing, fetching, downloading, or calling APIs.
