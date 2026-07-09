defmodule AllbertAssist.CLI do
  @moduledoc """
  The unified `allbert <group> <command>` dispatcher (v0.62 M3).

  Entry is the release `:mod` Application start; `bin/allbert` passes argv here
  and the launcher halts on the returned code (the Next LS pattern). Every
  operator command resolves through `AllbertAssist.CLI.Commands` — a registered
  action via `Actions.Runner.run/3`, a bounded read, or a dispatcher built-in
  (serve/first-run/help/version). Developer/CI commands are absent from the
  binary surface (they stay Mix tasks). No dispatcher command reaches a store
  directly (the `cli-command-inventory-spine-map-001` eval-row invariant).

  `run/1` is pure (returns `{output, exit_code}`) so it is fully unit-testable;
  `main/1` prints and halts.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Ask
  alias AllbertAssist.CLI.Commands
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Portability.Export
  alias AllbertAssist.Portability.Import
  alias AllbertAssist.Runtime.{Attach, WriterLock}
  alias AllbertAssist.Surfaces.ContextBuilder

  @doc """
  Print + halt entry called by the release launcher.

  Commands that reach the runtime (actions and DB-backed reads) need the OTP
  apps started — under `eval` they are only loaded. `main/1` first tries the
  local daemon attach transport. If no daemon is reachable, it starts the
  embedded fallback under the single-writer lock (Locked Decision 5); if the
  lock is held and attach is unavailable, it fails fast with repair guidance.
  Pure commands (help, version, first-run detection) skip runtime entirely.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {stream, output, code} = run_entry(argv)

    if output != "" do
      case stream do
        :stderr -> IO.puts(:stderr, output)
        :stdout -> IO.puts(output)
      end
    end

    System.halt(code)
  end

  @doc false
  @spec run_entry([String.t()]) :: {:stdout | :stderr, String.t(), non_neg_integer()}
  def run_entry(argv) do
    # v0.63 M8.1: under `mix release` `eval`, OTP apps are LOADED but not STARTED. Pure /
    # first-run commands skip the DB runtime, but still make HTTP calls (the Ollama
    # first-model probe on the post-completion `detect` path → Req), which need Req's
    # `Req.Finch` pool started by `Req.Application.start/2`. Start the HTTP client here —
    # idempotent, HTTP-only (no DB, no writer lock), so it does not breach the
    # "pure commands skip the runtime" invariant; `:req` is the HTTP client, not the
    # Allbert runtime. Runtime-needing commands already get it transitively.
    _ = Application.ensure_all_started(:req)

    case ensure_runtime(argv) do
      {:attached, output, code} ->
        maybe_attach_marker()
        {:stdout, output, code}

      :ok ->
        {output, code} = run(argv)
        {:stdout, output, code}

      {:error, message} ->
        {:stderr, message, 3}
    end
  end

  # v0.62 M8.9: prove attach vs embedded to the smoke harness / debugging without
  # polluting normal stdout — emit a one-line stderr marker only when asked.
  defp maybe_attach_marker do
    if System.get_env("ALLBERT_ATTACH_DEBUG") in ["1", "true"] do
      IO.puts(:stderr, "allbert: served by the running daemon (attached)")
    end
  end

  @doc false
  @spec run_attached([String.t()]) :: {String.t(), non_neg_integer()}
  def run_attached(argv), do: run(argv)

  # Start the OTP apps (embedded fallback) only when the resolved command needs
  # the runtime; guard with the writer lock so we never open a second writer
  # against a database a daemon already owns.
  defp ensure_runtime(argv) do
    if needs_runtime?(argv) do
      db = AllbertAssist.Database.repo_database_path()

      case classify_attach(Attach.run(argv)) do
        :fallback -> embedded_runtime(db)
        resolved -> resolved
      end
    else
      :ok
    end
  end

  @typedoc false
  @type attach_disposition ::
          {:attached, String.t(), non_neg_integer()} | {:error, String.t()} | :fallback

  # v0.62 M8.16: classify an Attach.run/1 result into what run_entry should do.
  # The core invariant: only a transport failure that happened BEFORE the daemon
  # ran the command may fall back to the embedded runtime — a reply-received
  # result (success, a non-zero exit, or a `{:command_crashed, _}`/undecodable
  # reply) must NEVER re-run the command embedded, or non-idempotent commands
  # (`secrets migrate`, `model install`, `service install`) would double-execute.
  @doc false
  @spec classify_attach(Attach.response()) :: attach_disposition()
  def classify_attach({:ok, {output, code}}), do: {:attached, output, code}

  def classify_attach({:error, reason})
      when reason in [
             :protocol_mismatch,
             :token_mismatch,
             :home_mismatch,
             :uid_mismatch,
             :version_mismatch
           ],
      do: {:error, "Could not attach to the running Allbert daemon: #{inspect(reason)}."}

  # Reply received: the command already ran on the daemon and crashed. Surface it,
  # never re-run embedded.
  def classify_attach({:error, {:command_crashed, message}}),
    do: {:error, "The running Allbert daemon failed to run the command: #{message}"}

  # A reply payload arrived but could not be decoded — the command was processed,
  # so do not retry.
  def classify_attach({:error, reason}) when reason in [:invalid_response, :invalid_term],
    do:
      {:error,
       "The running Allbert daemon returned an unreadable reply (#{inspect(reason)}); " <>
         "the command may have already run. Not retrying to avoid double execution."}

  # The daemon is alive but at its concurrency cap. The command did not run, but
  # the daemon owns the database, so the embedded fallback would only hit the
  # single-writer lock — ask the operator to retry instead.
  def classify_attach({:error, :busy}),
    do: {:error, "The running Allbert daemon is busy; please retry the command."}

  # Transport failed before any reply (:not_available/:closed/:timeout/
  # :econnrefused/:enoent/posix) — the command did NOT run on the daemon, so the
  # embedded fallback is safe.
  def classify_attach({:error, _reason}), do: :fallback

  defp embedded_runtime(db) do
    cond do
      is_nil(db) ->
        start_apps()

      WriterLock.held_by_another?(db) ->
        {:error,
         "Another Allbert runtime is using this database, but the attach " <>
           "transport is unavailable. Stop `allbert serve`, or repair the " <>
           "daemon's Allbert Home runtime socket."}

      true ->
        start_apps()
    end
  end

  defp needs_runtime?(argv) do
    case run_routing(argv) do
      {:action, _name} -> true
      {:read, _mod, _fun} -> true
      {:area, _module} -> true
      :builtin -> builtin_needs_runtime?(argv)
      _pure -> false
    end
  end

  # `ask` runs a live conversation turn, so it needs the embedded runtime (or a
  # daemon attach). serve/tui are launched by the overlay; chat/home reads open
  # their own resources.
  defp builtin_needs_runtime?(argv) do
    match?({["ask"], _}, resolve_path(argv))
  end

  defp run_routing(argv) do
    case argv do
      [] ->
        :first_run

      [flag] when flag in ["--help", "-h", "help", "--version", "version"] ->
        :pure

      _other ->
        {path, _rest} = resolve_path(argv)
        disposition_for(path)
    end
  end

  defp disposition_for(path) do
    case Commands.lookup(path) do
      {:ok, disposition} -> disposition
      :error -> :pure
    end
  end

  defp start_apps do
    case Application.ensure_all_started(:allbert_assist) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, "failed to start runtime: #{inspect(reason)}"}
    end
  end

  @doc "Pure dispatch: argv -> {rendered_output, exit_code}."
  @spec run([String.t()]) :: {String.t(), non_neg_integer()}
  def run(argv) do
    case argv do
      [] -> first_run()
      ["--help"] -> {help(), 0}
      ["-h"] -> {help(), 0}
      ["help"] -> {help(), 0}
      ["--version"] -> {version(), 0}
      ["version"] -> {version(), 0}
      _other -> dispatch(argv)
    end
  end

  # -- routing ---------------------------------------------------------------

  defp dispatch(argv) do
    {path, rest} = resolve_path(argv)

    case Commands.lookup(path) do
      {:ok, {:action, name}} -> run_action(name, rest)
      {:ok, {:read, mod, fun}} -> run_read(mod, fun, rest)
      {:ok, {:area, module}} -> run_area(module, rest)
      {:ok, :builtin} -> run_builtin(path, rest)
      {:ok, :mix_only} -> {mix_only_message(path), 2}
      {:ok, :retired} -> {"That command was retired.", 2}
      :error -> unknown(path)
    end
  end

  # v0.62 M8.7: an area dispatcher owns its subcommands and returns
  # {output, exit_code} from a release-safe module shared with the Mix task.
  defp run_area(module, rest) do
    module.dispatch(rest, ContextBuilder.cli_context(%{surface: "cli", channel: :cli}))
  rescue
    error -> {"error: #{Exception.message(error)}", 1}
  end

  # Resolve the longest matching table path (so `admin settings get` beats
  # `admin settings`), returning {path, remaining_args}. Words are the leading
  # non-flag args; flags and any leftover words become the command's rest.
  defp resolve_path(argv) do
    {words, flags} = Enum.split_while(argv, &(not String.starts_with?(&1, "-")))

    case longest_table_prefix(words) do
      nil -> {words, flags}
      path -> {path, Enum.drop(words, length(path)) ++ flags}
    end
  end

  defp longest_table_prefix([]), do: nil

  defp longest_table_prefix(words) do
    Enum.find_value(length(words)..1//-1, fn k ->
      prefix = Enum.take(words, k)
      if Map.has_key?(Commands.operator_table(), prefix), do: prefix
    end)
  end

  defp run_action(name, rest) do
    context = ContextBuilder.cli_context(%{surface: "cli", channel: :cli})
    {:ok, result} = Runner.run(name, params_from(name, rest), context)
    status = Map.get(result, :status)
    # The action result map carries the status; a non-completed status is a
    # non-zero exit so scripts can branch on it.
    code = if status in [:completed, nil], do: 0, else: 1
    {render_action_result(result, status), code}
  end

  # v0.62 M8.8: a confirmation-gated command (model install, service install,
  # secrets migrate, …) returns needs_confirmation; tell the operator how to
  # complete it through the CLI approve path (no daemon/web needed).
  defp render_action_result(result, :needs_confirmation) do
    render_result(result) <>
      "\n\nThis command needs operator confirmation. Review and approve:\n" <>
      "  allbert admin confirmations list\n" <>
      "  allbert admin confirmations approve <ID>"
  end

  defp render_action_result(result, _status), do: render_result(result)

  defp run_read(mod, fun, _rest) do
    case apply(mod, fun, []) do
      {:ok, value} -> {render_result(value), 0}
      other -> {render_result(other), 0}
    end
  rescue
    error -> {"error: #{Exception.message(error)}", 1}
  end

  defp run_builtin(["serve"], _rest),
    do: {"`allbert serve` is handled by the release launcher.", 0}

  defp run_builtin(["ask"], rest), do: Ask.run(rest)

  # `tui` is interactive (raw mode, blocks): the launcher overlay runs it in a
  # real TTY via `AllbertAssist.CLI.Tui.launch/0`. Reaching this pure clause
  # means it was invoked outside the launcher (e.g. `eval`), where a blocking
  # console cannot own the terminal — point the operator at the entry.
  defp run_builtin(["tui"], _rest),
    do: {"Run `allbert tui` from the installed binary (the launcher owns the TTY).", 0}

  defp run_builtin(["chat"], _rest), do: {chat_message(), 0}

  defp run_builtin(["admin", "home", "export"], rest) do
    opts = if out = out_flag(rest), do: [out: out], else: []

    case Export.build(opts) do
      {:ok, envelope} -> {render_result(%{message: "exported", envelope: summarize(envelope)}), 0}
      {:error, reason} -> {"export failed: #{inspect(reason)}", 1}
    end
  end

  defp run_builtin(["admin", "home", "import"], rest) do
    case rest do
      [path | _] ->
        case Import.dry_run(path) do
          {:ok, summary} -> {render_result(%{message: "import dry-run", summary: summary}), 0}
          {:error, reason} -> {"import failed: #{inspect(reason)}", 1}
        end

      [] ->
        {"usage: allbert admin home import PATH", 2}
    end
  end

  defp run_builtin(_path, _rest), do: {help(), 0}

  defp chat_message do
    port = System.get_env("PORT") || "4000"

    """
    Allbert web workspace chat: http://localhost:#{port}/workspace
    Start the server first if it is not running: allbert serve
    For a terminal session instead, run: allbert tui
    """
    |> String.trim()
  end

  defp out_flag(rest) do
    case Enum.drop_while(rest, &(&1 != "--out")) do
      ["--out", value | _] -> value
      _none -> nil
    end
  end

  defp summarize(envelope),
    do: Map.take(envelope, [:schema_version, "schema_version", :version, "version"])

  # -- bare `allbert`: first-run/resume dispatcher ---------------------------

  defp first_run do
    state = FirstRun.detect()

    body =
      case state do
        :home_missing ->
          "Allbert Home is not set up yet. Run `allbert serve` to initialize it, " <>
            "then complete onboarding (v0.63)."

        :schema_incompatible ->
          "Allbert Home needs a schema upgrade before it can start. See the upgrade guide."

        :onboarding_incomplete ->
          "Onboarding is incomplete. Run `allbert serve --open` to resume the wizard."

        :first_model_not_ready ->
          "No usable model yet (state: #{FirstRun.first_model_state()}). " <>
            "Run model setup, or provide a provider key (BYOK)."

        :profile_unreviewed ->
          "A profile is pending review. Run `allbert admin onboarding`."

        :product_ready ->
          "Allbert is ready. Run `allbert serve` to start, or `allbert --help`."
      end

    {body, 0}
  end

  # -- rendering + params ----------------------------------------------------

  defp params_from("operator_setting_get", [key | _rest]), do: %{key: key}

  defp params_from("service_control", rest) do
    {positionals, flags, options} = split_flags(rest)

    %{}
    |> maybe_put(:operation, List.first(positionals))
    |> maybe_put(:dry_run, flag?(flags, "--dry-run") or flag?(flags, "--dry_run"))
    |> maybe_put(:binary, flag_value(options, "--binary"))
  end

  defp params_from("install_ollama", rest) do
    {_positionals, flags, _options} = split_flags(rest)
    %{dry_run: flag?(flags, "--dry-run") or flag?(flags, "--dry_run")}
  end

  defp params_from("pull_model", rest) do
    {positionals, flags, options} = split_flags(rest)

    %{}
    |> maybe_put(:dry_run, flag?(flags, "--dry-run") or flag?(flags, "--dry_run"))
    |> maybe_put(:model, flag_value(options, "--model") || List.first(positionals))
  end

  defp params_from(_name, _rest), do: %{}

  defp split_flags(rest) do
    parse_args(rest, [], [], %{})
    |> then(fn {positionals, flags, options} ->
      {Enum.reverse(positionals), Enum.reverse(flags), options}
    end)
  end

  defp parse_args([flag, value | rest], positionals, flags, options)
       when flag in ["--binary", "--model"] do
    if String.starts_with?(value, "-") do
      parse_args([value | rest], positionals, [flag | flags], options)
    else
      parse_args(rest, positionals, [flag | flags], Map.put(options, flag, value))
    end
  end

  defp parse_args([flag | rest], positionals, flags, options)
       when is_binary(flag) and byte_size(flag) > 0 and binary_part(flag, 0, 1) == "-" do
    parse_args(rest, positionals, [flag | flags], options)
  end

  defp parse_args([positional | rest], positionals, flags, options) do
    parse_args(rest, [positional | positionals], flags, options)
  end

  defp parse_args([], positionals, flags, options), do: {positionals, flags, options}

  defp flag?(flags, flag), do: flag in flags

  defp flag_value(options, flag), do: Map.get(options, flag)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp render_result(%{message: message}) when is_binary(message), do: message
  defp render_result(map) when is_map(map), do: inspect(map, pretty: true, limit: :infinity)
  defp render_result(other), do: inspect(other, pretty: true)

  defp help do
    """
    Allbert - local-first assistant workspace

    Start
      allbert serve            Start the local runtime + web workspace
      allbert chat             Open or start web workspace chat
      allbert ask "..."        Ask one question
      allbert tui              Open the terminal operator console

    Set up
      allbert                  Resume setup or open the product
      allbert onboard          Guided first-run wizard (QuickStart/Advanced)
      allbert admin onboarding Review setup state
      allbert admin models     Check model/provider readiness
      allbert admin vault      Show the secret-vault tier

    Operate (each `admin <area>` has its own subcommands; run one for usage)
      allbert admin status | health | trace | registry | events
      allbert admin settings | channels | jobs | objectives | confirmations
      allbert admin threads | sessions | memory | skills | plugins | apps
      allbert admin mcp | intent | workspace | workflows | plan | tools
      allbert admin resources | marketplace | packages | external | exec
      allbert admin voice | trust | self-improvement | public_protocol
      allbert admin service | secrets migrate | home export|import

    Development and CI stay under mix (mix allbert.<area> mirrors admin <area>).
    """
    |> String.trim_trailing()
  end

  defp version do
    "allbert #{Application.spec(:allbert_assist, :vsn)}"
  end

  defp mix_only_message(path) do
    "`allbert #{Enum.join(path, " ")}` is a developer/CI command — use the Mix " <>
      "task in a checkout (mix allbert.*)."
  end

  defp unknown(path) do
    {"unknown command: allbert #{Enum.join(path, " ")}\nRun `allbert --help`.", 2}
  end
end
