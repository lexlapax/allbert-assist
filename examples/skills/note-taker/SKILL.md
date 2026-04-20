---
name: note-taker
description: Capture short notes into project files.
intents: [task, memory_query]
allowed-tools: write_file request_input
---

# Note Taker

When the user wants a durable note captured, ask for any missing destination details
with `request_input`, then write a concise markdown note with `write_file`.
