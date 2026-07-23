defmodule AllbertAssist.CLI.Commands do
  @moduledoc """
  The v0.62 M3 disposition table: every operator-facing `allbert` command and
  every Mix task, mapped to exactly one disposition. This is the data the
  `cli-command-inventory-spine-map-001` eval row asserts against — no
  dispatcher command may reach a store directly; each is a registered action,
  a read module, a built-in (serve/first-run/help), or explicitly `:mix_only`.

  Dispositions:

    * `{:action, name}`    — routes through `Actions.Runner.run/3` (the spine).
    * `{:read, mod, fun}`  — a bounded read function (no store writes).
    * `{:area, module}`    — an area dispatcher owning its subcommands, shared
      release-safe with `mix allbert.<area>` (`CLI.Areas.<Area>.dispatch/2`).
    * `:builtin`           — dispatcher-native (serve, first-run, help, version).
    * `:mix_only`          — developer/CI; stays a Mix task, absent from the binary.
    * `:retired`           — superseded; no command.

  Ratified against `docs/design/entry-point-cli-ux.md` at request-flow S4.
  """

  alias AllbertAssist.CLI.Areas

  @typedoc ~S(One dispatcher path, e.g. `["admin", "status"]` or `["ask"]`.)
  @type path :: [String.t()]
  @type disposition ::
          {:action, String.t()}
          | {:read, module(), atom()}
          | {:area, module()}
          | :builtin
          | :mix_only
          | :retired

  # ---- operator surface on the binary --------------------------------------

  @operator %{
    # Product entry points — call Runtime/boot directly, not an admin read.
    ["ask"] => :builtin,
    ["chat"] => :builtin,
    ["tui"] => :builtin,
    ["serve"] => :builtin,
    ["gen"] => :mix_only,
    # v0.63 M1: `allbert onboard` is a new top-level verb (Locked Decision 7) — a
    # flag-bearing area dispatcher for the guided wizard. `admin onboarding` stays
    # the read-only summary.
    ["onboard"] => {:area, Areas.Onboarding},
    # `allbert admin <area> [cmd]` — thin views over registered reads/actions.
    ["admin", "status"] => {:action, "operator_status"},
    ["admin", "events"] => {:action, "operator_events"},
    ["admin", "trace"] => {:action, "trace_summary"},
    ["admin", "registry"] => {:action, "registry_health"},
    # First-Model-Path (M4): detect/install/pull stay explicit action paths
    # under the `model` prefix; `admin models` (plural) is the Model area.
    ["admin", "model", "detect"] => {:action, "first_model_detect"},
    ["admin", "model", "install"] => {:action, "install_ollama"},
    ["admin", "model", "pull"] => {:action, "pull_model"},
    ["admin", "health"] => {:action, "serve_health"},
    ["admin", "cancellation-proof"] => {:area, Areas.CancellationProof},
    ["admin", "service", "status"] => {:action, "serve_health"},
    ["admin", "service"] => {:action, "service_control"},
    ["admin", "db"] => {:area, Areas.Database},
    ["admin", "vault"] => {:action, "vault_status"},
    ["admin", "secrets", "migrate"] => {:action, "migrate_secrets"},
    ["admin", "onboarding"] => {:read, AllbertAssist.CLI.FirstRun, :onboarding_summary},
    # v0.59 portability boundary (read DB + file I/O; no store mutation).
    ["admin", "home", "export"] => :builtin,
    ["admin", "home", "import"] => :builtin,
    # v0.62 M8.7 — area dispatchers own their subcommands (the longest-prefix
    # resolver stops at the area; the rest of argv is passed to dispatch/2).
    # Each `{:area, mod}` shares its logic with `mix allbert.<area>`.
    ["admin", "apps"] => {:area, Areas.Apps},
    ["admin", "channels"] => {:area, Areas.Channels},
    ["admin", "confirmations"] => {:area, Areas.Confirmations},
    ["admin", "jobs"] => {:area, Areas.Jobs},
    ["admin", "objectives"] => {:area, Areas.Objectives},
    ["admin", "models"] => {:area, Areas.Model},
    ["admin", "memory"] => {:area, Areas.Memory},
    ["admin", "notes"] => {:area, Areas.Notes},
    ["admin", "sessions"] => {:area, Areas.Sessions},
    ["admin", "skills"] => {:area, Areas.Skills},
    ["admin", "threads"] => {:area, Areas.Threads},
    ["admin", "intent"] => {:area, Areas.Intent},
    ["admin", "workspace"] => {:area, Areas.Workspace},
    ["admin", "workflows"] => {:area, Areas.Workflows},
    ["admin", "plan"] => {:area, Areas.Plan},
    ["admin", "mcp"] => {:area, Areas.Mcp},
    ["admin", "plugins"] => {:area, Areas.Plugins},
    ["admin", "resources"] => {:area, Areas.Resources},
    ["admin", "tools"] => {:area, Areas.Tools},
    ["admin", "voice"] => {:area, Areas.Voice},
    ["admin", "trust"] => {:area, Areas.Trust},
    ["admin", "self-improvement"] => {:area, Areas.SelfImprovement},
    ["admin", "public_protocol"] => {:area, Areas.PublicProtocol},
    ["admin", "exec"] => {:area, Areas.Exec},
    ["admin", "external"] => {:area, Areas.External},
    ["admin", "packages"] => {:area, Areas.Packages},
    ["admin", "settings"] => {:area, Areas.Settings},
    ["admin", "marketplace"] => {:area, Areas.Marketplace}
  }

  # ---- developer / CI: Mix-only, never on the binary -----------------------

  @mix_only ~w(
    test test.raw hex_audit ecto.migrate sandbox validate_app
    gen.app gen.plugin gen.flow gen.tool gen.support
  )

  # ---- Mix tasks mapped to their binary home (for the reverse mapping) -----
  # Every core Mix task classified. Operator tasks re-front onto the paths
  # above; the rest stay mix_only.

  @task_dispositions %{
    "ask" => {:command, ["ask"]},
    "tui" => {:command, ["tui"]},
    "channels" => {:command, ["admin", "channels"]},
    "confirmations" => {:command, ["admin", "confirmations"]},
    "jobs" => {:command, ["admin", "jobs"]},
    "objectives" => {:command, ["admin", "objectives"]},
    "settings" => {:command, ["admin", "settings"]},
    "security" => {:command, ["admin", "trust"]},
    "onboard" => {:command, ["onboard"]},
    "model" => {:command, ["admin", "models"]},
    "home.export" => {:command, ["admin", "home", "export"]},
    "home.import" => {:command, ["admin", "home", "import"]},
    "objective" => {:command, ["admin", "objectives"]},
    "plugins" => {:command, ["admin", "plugins"]},
    "apps" => {:command, ["admin", "apps"]},
    "mcp" => {:command, ["admin", "mcp"]},
    "public_protocol" => {:command, ["admin", "public_protocol"]},
    "marketplace" => {:command, ["admin", "marketplace"]},
    "threads" => {:command, ["admin", "threads"]},
    "conversations" => {:command, ["admin", "threads"]},
    "sessions" => {:command, ["admin", "sessions"]},
    "memory" => {:command, ["admin", "memory"]},
    "notes" => {:command, ["admin", "notes"]},
    "intent" => {:command, ["admin", "intent"]},
    "workspace" => {:command, ["admin", "workspace"]},
    "workflows" => {:command, ["admin", "workflows"]},
    "plan" => {:command, ["admin", "plan"]},
    "resources" => {:command, ["admin", "resources"]},
    "tools" => {:command, ["admin", "tools"]},
    "skills" => {:command, ["admin", "skills"]},
    "delegate" => {:command, ["admin", "objectives"]},
    "self_improvement" => {:command, ["admin", "self-improvement"]},
    "dynamic" => {:command, ["admin", "plugins"]},
    "exec" => {:command, ["admin", "exec"]},
    "external" => {:command, ["admin", "external"]},
    "packages" => {:command, ["admin", "packages"]},
    "voice.local" => {:command, ["admin", "voice"]},
    "mcp_server" => {:command, ["serve"]},
    "acp_server" => {:command, ["serve"]},
    # developer / CI
    "test" => :mix_only,
    "test.raw" => :mix_only,
    "hex_audit" => :mix_only,
    "ecto.migrate" => :mix_only,
    "sandbox" => :mix_only,
    "validate_app" => :mix_only,
    "gen.app" => :mix_only,
    "gen.plugin" => :mix_only,
    "gen.flow" => :mix_only,
    "gen.tool" => :mix_only,
    "gen.support" => :mix_only
  }

  @doc "The full operator dispatch table (path -> disposition)."
  @spec operator_table() :: %{path() => disposition()}
  def operator_table, do: @operator

  @doc "Look up one dispatch path."
  @spec lookup(path()) :: {:ok, disposition()} | :error
  def lookup(path) when is_list(path) do
    case Map.fetch(@operator, path) do
      {:ok, disposition} -> {:ok, disposition}
      :error -> :error
    end
  end

  @doc "Mix-task -> `allbert` mapping (the reverse doc deliverable)."
  @spec task_dispositions() :: %{String.t() => {:command, path()} | :mix_only}
  def task_dispositions, do: @task_dispositions

  @doc "Group names surfaced in `allbert --help`."
  @spec groups() :: [String.t()]
  # `gen` is developer/CI only (:mix_only) and absent from the binary surface, so
  # it is not a product command group (v0.62 M8.11). v0.63 M7.1: `onboard` is the
  # top-level guided-wizard verb and must be discoverable in the operator surface.
  def groups, do: ["ask", "chat", "tui", "serve", "onboard", "admin"]

  @doc "True when a Mix task is developer/CI only (must be absent from the binary)."
  @spec mix_only?(String.t()) :: boolean()
  def mix_only?(task), do: task in @mix_only
end
