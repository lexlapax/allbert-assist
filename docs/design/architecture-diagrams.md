# Allbert Architecture Diagrams

Visual orientation for the current implementation line, verified against the
code rather than inferred from plans. The final section is the in-flight
release-train map; use the active plan for milestone landing and release status.

Diagrams are Mermaid and render natively on GitHub. When a diagram and the code
disagree, the code wins — these are orientation aids, not contracts. The binding
contracts live in the [ADRs](../adr/README.md), and the subsystem routing map
for deeper work is
[agent-context-map](../developer/agent-context-map.md).

Two ideas explain most of the layout below. First, **every surface goes through
one runtime**: asking from the browser and asking from the terminal produce the
same authority decisions. Second, **authority comes from registered actions,
settings, policy checks, and confirmations** — never from model output, plugin
metadata, YAML, or a surface being the one that asked.

---

## 1. Component map

The whole system, from surfaces down to storage. Everything in the Surfaces row
adapts input and renders output; none of it decides what is allowed.

```mermaid
flowchart TB
    subgraph SURF["Surfaces — render and dispatch only"]
        WEB["Web workspace<br/>Phoenix LiveView"]
        TUI["Terminal TUI"]
        CLI["CLI commands"]
        CHAN["Chat channels<br/>Slack · Discord · Telegram<br/>Matrix · Signal · WhatsApp · Email"]
        PROTO["Public protocols<br/>ACP · MCP · OpenAI-compatible"]
    end

    subgraph SPINE["Runtime spine"]
        RT["AllbertAssist.Runtime<br/>submit_user_input/1"]
        INTENT["Intent.Engine.decide/2<br/>classify · rank · route"]
        RUNNER["Actions.Runner.run/3"]
        REG["Actions.Registry<br/>the capability roster"]
    end

    subgraph AUTH["Authority — the boundary"]
        SEC["Security Central<br/>Policy · PermissionGate<br/>Risk · Decision · Audit"]
        SET["Settings Central<br/>typed operator config"]
        CONF["Confirmations<br/>durable, same-channel proof"]
    end

    subgraph DOM["Domains"]
        MEM["Memory<br/>markdown-first, reviewed"]
        CONV["Conversations<br/>threads and messages"]
        OBJ["Objectives<br/>multi-step durable work"]
        JOBS["Jobs<br/>the only scheduler"]
        WS["Workspace<br/>canvas and fragments"]
        EXEC["Execution<br/>supervised host processes"]
    end

    subgraph EXT["Reviewed extensions"]
        PLUG["Source-tree plugins"]
        APPS["App surfaces<br/>StockSage"]
        SKILL["Skills"]
    end

    subgraph STORE["Storage — Allbert Home"]
        DB[("SQLite<br/>allbert.sqlite3")]
        MD["Markdown<br/>memory and traces"]
        ART["Artifacts"]
        SECRETS["Encrypted secrets<br/>Key Custody"]
    end

    WEB --> RT
    TUI --> RT
    CLI --> RT
    CHAN --> RT
    PROTO --> RT

    RT --> INTENT
    INTENT --> RUNNER
    RUNNER --> REG
    RUNNER --> SEC
    SEC --> CONF
    SEC -.reads.-> SET

    RUNNER --> MEM
    RUNNER --> CONV
    RUNNER --> OBJ
    RUNNER --> JOBS
    RUNNER --> WS
    RUNNER --> EXEC

    PLUG -.register actions.-> REG
    APPS -.register actions.-> REG
    SKILL -.register actions.-> REG

    MEM --> MD
    CONV --> DB
    OBJ --> DB
    JOBS --> DB
    WS --> DB
    SET --> DB
    SET --> SECRETS
    RUNNER -.trace.-> MD
    EXEC --> ART

    classDef auth fill:#4a3a5a,stroke:#8a6aaa,color:#f0e8ff
    classDef store fill:#2a3a4a,stroke:#5a7a9a,color:#e0f0ff
    class SEC,SET,CONF auth
    class DB,MD,ART,SECRETS store
```

The arrow that matters most is the dotted one from **Reviewed extensions** into
the registry. A plugin, app, or skill does not gain capability by existing; it
registers actions, and those actions are subject to exactly the same policy and
confirmation checks as built-in ones.

---

## 2. One process, many surfaces

The packaged product runs a single daemon per Allbert Home. A writer lock makes
that structural rather than advisory: a second process that tries to boot
against the same Home refuses instead of becoming a competing SQLite writer.

```mermaid
flowchart LR
    subgraph HOST["One machine, one Allbert Home"]
        subgraph DAEMON["allbert serve — the daemon"]
            LOCK{{"single-writer lock"}}
            RUNTIME["Runtime · Repo · identity<br/>confirmations · jobs · fan-out"]
            ATTACH["Attach listener<br/>Unix socket + per-Home token"]
            PHX["Phoenix endpoint"]
        end

        BROWSER["Browser"] -->|HTTP / WebSocket| PHX
        ONESHOT["one-shot CLI<br/>allbert status, jobs, memory"] -->|attach request| ATTACH
        TERM["allbert tui<br/>thin terminal client"] -->|"authenticated session frames"| ATTACH
        PHX --> RUNTIME
        ATTACH --> RUNTIME
        LOCK -.guards.-> RUNTIME
    end
```

ADR 0091 makes `allbert tui` a thin authenticated client of the same daemon.
The daemon owns Runtime and durable session state; the client owns terminal
input, rendering, resize, and restoration. Web and one TUI can therefore remain
open concurrently against one Home without a second Repo or writer.

---

## 3. A chat turn, end to end

What actually happens between typing and an answer. This is the direct-answer
path — the one that consults memory.

```mermaid
sequenceDiagram
    autonumber
    actor OP as Operator
    participant S as Surface
    participant RT as Runtime
    participant IE as Intent.Engine
    participant AM as ActiveMemory
    participant AR as Actions.Runner
    participant SEC as Security Central
    participant P as Provider
    participant TR as Trace

    OP->>S: types a message
    S->>RT: submit_user_input/1
    RT->>RT: admit turn, dedupe, resolve identity
    RT->>IE: decide/2

    Note over IE: classify, rank candidates,<br/>pick a route

    alt Direct answer
        IE-->>RT: direct_answer
        RT->>AR: retrieve_active_memory
        AR->>SEC: policy check
        SEC-->>AR: allowed
        AR->>AM: candidates for this query
        AM-->>AR: reviewed :kept entries only
        AR-->>RT: scored, budgeted chunks
        RT->>P: prompt + memory block
        P-->>RT: completion
    else Routed to an action
        IE-->>RT: action candidate
        RT->>AR: run/3
        AR->>SEC: policy check
        SEC-->>AR: allowed / needs confirmation / denied
        AR-->>RT: typed result
    end

    RT->>TR: record turn, redacted
    RT-->>S: response
    S-->>OP: rendered answer
```

Two details are load-bearing. Memory candidates are filtered to
operator-reviewed `:kept` entries **before** scoring, so an unreviewed note
cannot reach a prompt by ranking well. And the trace is written after the fact
through the redactor, so secrets never land in the record of what happened.

---

## 4. The authority boundary

Every effect takes this path. There is no side door for plugins, apps, model
output, or a surface that "already knows" the operator approved something.

```mermaid
flowchart TD
    REQ["Action request<br/>name + params + context"] --> REG{"Registered in<br/>Actions.Registry?"}
    REG -->|no| DENY1["denied — unknown action"]
    REG -->|yes| POL{"Security policy<br/>permission · risk · exposure"}

    POL -->|denied| DENY2["denied + audit"]
    POL -->|allowed| RUN["execute"]
    POL -->|confirmation required| PEND["create durable confirmation"]

    PEND --> ASK["ask on the originating channel"]
    ASK --> WAIT{"operator decides"}
    WAIT -->|approve| PROOF{"same-channel<br/>callback proof"}
    WAIT -->|reject| DENY3["rejected + audit"]
    WAIT -->|expires| DENY4["expired + audit"]

    PROOF -->|valid| RUN
    PROOF -->|invalid| DENY5["denied + audit"]

    RUN --> EFFECT["effect happens"]
    EFFECT --> AUDIT["audit + trace, redacted"]
    DENY1 --> AUDIT
    DENY2 --> AUDIT
    DENY3 --> AUDIT
    DENY4 --> AUDIT
    DENY5 --> AUDIT

    classDef deny fill:#4a2a2a,stroke:#a06060,color:#ffe8e8
    classDef go fill:#2a4a2a,stroke:#60a060,color:#e8ffe8
    class DENY1,DENY2,DENY3,DENY4,DENY5 deny
    class RUN,EFFECT go
```

The **same-channel callback proof** is the part people miss: approving in Slack
authorizes the thing that was asked in Slack. An approval cannot be replayed
from a different surface, and possession of a confirmation id is not authority.

---

## 5. Supervision tree

The OTP shape, which is also the failure-isolation story. Optional children
start based on mode and settings — a one-shot CLI invocation starts far less
than a daemon.

```mermaid
flowchart TD
    SUP["AllbertAssist.Supervisor<br/>one_for_one"]

    SUP --> REPO["Repo"]
    SUP --> WLOCK["writer lock<br/>serve mode only"]
    SUP --> PUBSUB["Phoenix.PubSub"]
    SUP --> BUS["Jido.Signal.Bus"]
    SUP --> SETSUP["Settings.Supervisor"]
    SUP --> TASKS["Task.Supervisor"]

    SUP --> EXECREG["Execution.ProcessRegistry"]
    SUP --> EXECOWN["Execution.ProcessOwners"]

    SUP --> OBJREG["Objectives.AgentRegistry"]
    SUP --> OBJSUP["Objectives.Runs.Supervisor"]
    SUP --> OBJSCHED["Objectives.Runs.Scheduler"]

    SUP --> ROUTIDX["Intent.Router.Index"]
    SUP --> ROUTPEND["Intent.Router.PendingStore"]

    SUP --> JIDO["Jido"]
    SUP --> GC["Artifacts.GC"]
    SUP --> RATE["PublicProtocol.RateLimiter"]
    SUP --> SWEEP["PublicProtocol.ResultReadbackSweeper"]

    SUP -.optional.-> PLUGSUP["Plugin.Supervisor"]
    SUP -.optional.-> APPSUP["App.Supervisor"]
    SUP -.optional.-> DYNSUP["DynamicPlugins.Supervisor"]
    SUP -.optional.-> JIDOSUP["JidoBacked.Supervisor"]
    SUP -.optional.-> SCRATCH["Session.Scratchpad<br/>volatile ETS"]
    SUP -.optional.-> CHANSUP["Channels.Supervisor"]
    SUP -.optional.-> ATTACHSRV["Attach.Server"]

    classDef opt stroke-dasharray: 4 4
    class PLUGSUP,APPSUP,DYNSUP,JIDOSUP,SCRATCH,CHANSUP,ATTACHSRV opt
```

`Execution.ProcessOwners` is worth naming: host processes Allbert spawns are
owned and supervised, so a crashed turn does not orphan a child process. OTP
supervision is failure isolation, not an OS security boundary — host execution
is bounded by policy, not by the process tree.

---

## 6. Allbert Home

All durable operator data lives under one directory, which is what makes
"delete this folder and Allbert is gone" true.

```mermaid
flowchart TD
    HOME["ALLBERT_HOME<br/>default ~/.allbert"]

    HOME --> DB["db/allbert.sqlite3<br/>conversations · objectives · jobs<br/>confirmations · workspace · settings"]
    HOME --> BACKUPS["db/backups/<br/>pre-migration copies"]
    HOME --> MEMORY["memory/<br/>markdown, source of truth"]
    HOME --> ARTIFACTS["artifacts/<br/>generated outputs"]
    HOME --> DRAFTS["drafts/<br/>supervised suggestions"]
    HOME --> RUNTIME_D["runtime/<br/>attach socket + token"]

    MEMORY --> CATS["notes · preferences<br/>skills · identity"]
    MEMORY --> TRACES["traces/<br/>redacted turn records"]
    MEMORY --> DELETED["deleted/<br/>archive by month"]

    classDef canon fill:#2a3a4a,stroke:#5a7a9a,color:#e0f0ff
    class DB,MEMORY canon
```

Markdown is authority for memory; SQLite is authority for everything
relational. Backups are taken before schema migrations, and a boot that cannot
write a backup refuses to migrate rather than proceeding unprotected.

---

## 7. Where v1.2.6 and v1.3 landed

Both stages are shipped: v1.2.6 delivered the thin client and packaged license
seams, and v1.3.0 delivered Memory and Search Central. See the
[archived v1.3 plan](../plans/archives/v1.3-plan.md), ADR 0091, ADR 0092, and
ADR 0093.

```mermaid
flowchart TB
    subgraph V121["v1.2.6 — foundational binary"]
        LIC["Packaged license inventory<br/>+ offline allbert licenses viewer"]
        THIN["Thin TUI client<br/>one daemon owns the runtime"]
        PROMO["Split build from publication<br/>protected promotion, no rebuild"]
    end

    subgraph V13["v1.3 — memory and search"]
        CORPUS["Conversations.Corpus<br/>the canonical boundary"]
        CLAIMS["Memory claims<br/>append-only, bi-temporal"]
        PROP["Proposals → review → kept"]
        SEARCH["Search Central<br/>FTS5 projection"]
        DEL["Canonical conversation delete"]
    end

    V121 ==>|serial barrier:<br/>published and accepted| V13

    CORPUS --> CLAIMS
    CORPUS --> SEARCH
    CLAIMS --> PROP
    DEL -.invalidates.-> SEARCH
    DEL -.stales.-> PROP
    SEARCH -.->|never| CLAIMS

    classDef shipped fill:#243a2a,stroke:#60a070,color:#f0fff4
    class LIC,THIN,PROMO,CORPUS,CLAIMS,PROP,SEARCH,DEL shipped
```

The crossed-out edge is deliberate: Search never feeds Memory. Being able to
*find* a message does not make it eligible to become a remembered fact about the
operator — those are separate grants with separate consent, and there is no
promote-to-memory path from a search result.

Two acts that look similar are kept distinct. **Forget** removes what Allbert
concluded and leaves the conversation; **canonical delete** removes what was
said. Each disclosure names the other as the further step.

---

## Keeping these honest

These diagrams are orientation, and orientation rots. When a subsystem moves,
update the diagram in the same change or delete it — a confidently wrong diagram
costs more than no diagram. The ADRs, the active plan triad, and the code remain
the authority in that order.
