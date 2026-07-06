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
    * `:builtin`           — dispatcher-native (serve, first-run, help, version).
    * `:mix_only`          — developer/CI; stays a Mix task, absent from the binary.
    * `:retired`           — superseded; no command.

  Ratified against `docs/design/entry-point-cli-ux.md` at request-flow S4.
  """

  @typedoc "One dispatcher path, e.g. `[\"admin\", \"status\"]` or `[\"ask\"]`."
  @type path :: [String.t()]
  @type disposition ::
          {:action, String.t()}
          | {:read, module(), atom()}
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
    # `allbert admin <area> [cmd]` — thin views over registered reads/actions.
    ["admin", "status"] => {:action, "operator_status"},
    ["admin", "channels"] => {:action, "operator_channels"},
    ["admin", "confirmations"] => {:action, "operator_confirmations"},
    ["admin", "events"] => {:action, "operator_events"},
    ["admin", "settings", "get"] => {:action, "operator_setting_get"},
    ["admin", "jobs"] => {:action, "list_jobs"},
    ["admin", "objectives"] => {:action, "list_objectives"},
    ["admin", "trace"] => {:action, "trace_summary"},
    ["admin", "registry"] => {:action, "registry_health"},
    ["admin", "models"] => {:action, "model_doctor"},
    ["admin", "model", "detect"] => {:action, "first_model_detect"},
    ["admin", "model", "install"] => {:action, "install_ollama"},
    ["admin", "model", "pull"] => {:action, "pull_model"},
    ["admin", "health"] => {:action, "serve_health"},
    ["admin", "service"] => {:action, "service_control"},
    ["admin", "onboarding"] => {:read, AllbertAssist.CLI.FirstRun, :onboarding_summary},
    # v0.59 portability boundary (read DB + file I/O; no store mutation).
    ["admin", "home", "export"] => :builtin,
    ["admin", "home", "import"] => :builtin
  }

  # ---- developer / CI: Mix-only, never on the binary -----------------------

  @mix_only ~w(
    test test.raw ecto.migrate sandbox validate_app
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
    "onboard" => {:command, ["admin", "onboarding"]},
    "model" => {:command, ["admin", "models"]},
    "home.export" => {:command, ["admin", "home", "export"]},
    "home.import" => {:command, ["admin", "home", "import"]},
    "objective" => {:command, ["admin", "objectives"]},
    "plugins" => {:command, ["admin", "plugins"]},
    "apps" => {:command, ["admin", "apps"]},
    "mcp" => {:command, ["admin", "mcp"]},
    "public_protocol" => {:command, ["admin", "public_protocol"]},
    "marketplace" => {:command, ["admin", "apps"]},
    "threads" => {:command, ["admin", "threads"]},
    "conversations" => {:command, ["admin", "threads"]},
    "sessions" => {:command, ["admin", "sessions"]},
    "memory" => {:command, ["admin", "memory"]},
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
  def groups, do: ["ask", "chat", "tui", "serve", "admin", "gen"]

  @doc "True when a Mix task is developer/CI only (must be absent from the binary)."
  @spec mix_only?(String.t()) :: boolean()
  def mix_only?(task), do: task in @mix_only
end
