For an operator prompt, the intended v0.15 flow should be:

The channel receives input. CLI/REPL/TUI/Telegram attaches to a daemon session. The daemon locks the session kernel and calls the turn runner.

Kernel starts the turn. It increments turn state, enforces daily/turn budget, emits classifying_intent, and starts trace spans. This matches the current flow around lib.rs (line 913).

Optional pre-router RAG hint runs. This should be tiny and probably lexical-only: command catalog, settings catalog, and operator-help snippets only. It should not run full vector search for every prompt. Its job is to help the router understand “is this a help/settings/command question?”, not to feed full context to the final answer.

Intent router runs. It returns task, chat, schedule, memory_query, or meta, plus possible action drafts. The current schema-bound router is at intent.rs (line 7) and the LLM router call is at lib.rs (line 2353).

If the router returns a high-confidence terminal action, the runtime may execute the guarded tool path before the primary assistant answer. Schedule and explicit memory capture already follow this shape via maybe_execute_router_action at lib.rs (line 2815). RAG should not bypass this.

Post-router RAG retrieval runs when eligible. For meta/help, search docs, commands, settings, and skill metadata. For memory_query, search durable memory, facts, episodes, and session summaries. For ordinary task, only retrieve when the router or explicit prompt says it needs local knowledge. For chat, usually no RAG.

RAG service searches. If vectors are healthy, it embeds the query through Ollama, runs sqlite-vec KNN plus SQLite FTS, fuses results, dedupes, caps bytes/chunks, and returns labelled snippets. If vectors are down/stale/disabled, it falls back to FTS and marks posture degraded.

Prompt assembly happens. Bootstrap files are loaded by the existing BeforePrompt hook path, then memory/RAG sections are appended, then the system prompt is built at lib.rs (line 3073). RAG snippets should be rendered as evidence with source labels, never as authority.

The primary LLM agent runs. There is no separate “RAG agent” in the normal path. RAG is a kernel service the runtime calls before the root model, plus possibly a read-only tool if v0.15 chooses to expose one. The root agent uses the retrieved context, then may call tools, spawn subagents, or answer normally.

Tool loop can trigger refresh. Current memory can schedule a refresh after external evidence at lib.rs (line 2709). v0.15 should decide whether RAG gets the same behavior after file/process/search-like tool results.

RAG indexing also runs outside turns. Manual CLI/REPL rebuilds call the daemon-owned RagMaintenanceService. Periodic indexing runs only through daemon maintenance, not through an LLM scheduled job. Startup can rebuild a missing DB; scheduled stale-only runs happen when rag.index.schedule_enabled is enabled; all runs share one rebuild lock and record rag_index_runs.