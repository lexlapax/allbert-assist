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
  alias AllbertAssist.CLI.Commands
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Surfaces.ContextBuilder

  @doc """
  Print + halt entry called by the release launcher.

  Commands that reach the runtime (actions and DB-backed reads) need the OTP
  apps started — under `eval` they are only loaded. `main/1` starts them under
  the single-writer lock for the embedded-fallback path (Locked Decision 5);
  if a daemon already holds the lock it fails fast with guidance (attach to the
  running daemon is M5). Pure commands (help, version, first-run detection)
  skip runtime entirely.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    code =
      case ensure_runtime(argv) do
        :ok ->
          {output, code} = run(argv)
          if output != "", do: IO.puts(output)
          code

        {:error, message} ->
          IO.puts(:stderr, message)
          3
      end

    System.halt(code)
  end

  # Start the OTP apps (embedded fallback) only when the resolved command needs
  # the runtime; guard with the writer lock so we never open a second writer
  # against a database a daemon already owns.
  defp ensure_runtime(argv) do
    if needs_runtime?(argv) do
      db = AllbertAssist.Database.repo_database_path()

      cond do
        is_nil(db) ->
          start_apps()

        AllbertAssist.Runtime.WriterLock.held_by_another?(db) ->
          {:error,
           "Another Allbert runtime is using this database (a daemon is likely " <>
             "running). Use the running instance, or stop `allbert serve` first."}

        true ->
          start_apps()
      end
    else
      :ok
    end
  end

  defp needs_runtime?(argv) do
    case run_routing(argv) do
      {:action, _name} -> true
      {:read, _mod, _fun} -> true
      _pure -> false
    end
  end

  defp run_routing(argv) do
    case argv do
      [] ->
        :first_run

      [flag] when flag in ["--help", "-h", "help", "--version", "version"] ->
        :pure

      _other ->
        resolve_path(argv)
        |> then(fn {path, _rest} ->
          case Commands.lookup(path) do
            {:ok, disposition} -> disposition
            :error -> :pure
          end
        end)
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
      {:ok, :builtin} -> run_builtin(path, rest)
      {:ok, :mix_only} -> {mix_only_message(path), 2}
      {:ok, :retired} -> {"That command was retired.", 2}
      :error -> unknown(path)
    end
  end

  # Resolve the longest matching table path (so `admin settings get` beats
  # `admin settings`), returning {path, remaining_args}. Words are the leading
  # non-flag args; flags and any leftover words become the command's rest.
  defp resolve_path(argv) do
    {words, flags} = Enum.split_while(argv, &(not String.starts_with?(&1, "-")))

    candidate =
      case length(words) do
        0 ->
          nil

        n ->
          Enum.find_value(n..1//-1, fn k ->
            prefix = Enum.take(words, k)
            if Map.has_key?(Commands.operator_table(), prefix), do: prefix
          end)
      end

    case candidate do
      nil -> {words, flags}
      path -> {path, Enum.drop(words, length(path)) ++ flags}
    end
  end

  defp run_action(name, rest) do
    context = ContextBuilder.cli_context(%{surface: "cli", channel: :cli})
    {:ok, result} = Runner.run(name, params_from(rest), context)
    # The action result map carries the status; a non-completed status is a
    # non-zero exit so scripts can branch on it.
    code = if Map.get(result, :status) in [:completed, nil], do: 0, else: 1
    {render_result(result), code}
  end

  defp run_read(mod, fun, _rest) do
    case apply(mod, fun, []) do
      {:ok, value} -> {render_result(value), 0}
      other -> {render_result(other), 0}
    end
  rescue
    error -> {"error: #{Exception.message(error)}", 1}
  end

  defp run_builtin(["serve"], _rest),
    do: {"`allbert serve` is handled by the release launcher (M5).", 0}

  defp run_builtin(["ask"], rest),
    do: {"ask: #{Enum.join(rest, " ")}", 0}

  defp run_builtin(["tui"], _rest),
    do: {"`allbert tui` opens the terminal console (M6).", 0}

  defp run_builtin(["chat"], _rest),
    do: {"`allbert chat` opens the web workspace chat.", 0}

  defp run_builtin(["admin", "home", "export"], rest) do
    opts = if out = out_flag(rest), do: [out: out], else: []

    case AllbertAssist.Portability.Export.build(opts) do
      {:ok, envelope} -> {render_result(%{message: "exported", envelope: summarize(envelope)}), 0}
      {:error, reason} -> {"export failed: #{inspect(reason)}", 1}
    end
  end

  defp run_builtin(["admin", "home", "import"], rest) do
    case rest do
      [path | _] ->
        case AllbertAssist.Portability.Import.dry_run(path) do
          {:ok, summary} -> {render_result(%{message: "import dry-run", summary: summary}), 0}
          {:error, reason} -> {"import failed: #{inspect(reason)}", 1}
        end

      [] ->
        {"usage: allbert admin home import PATH", 2}
    end
  end

  defp run_builtin(_path, _rest), do: {help(), 0}

  defp out_flag(rest) do
    case Enum.drop_while(rest, &(&1 != "--out")) do
      ["--out", value | _] -> value
      _none -> nil
    end
  end

  defp summarize(envelope) when is_map(envelope),
    do: Map.take(envelope, [:schema_version, "schema_version", :version, "version"])

  defp summarize(other), do: other

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

  defp params_from(_rest), do: %{}

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
      allbert admin onboarding Review setup state
      allbert admin models     Check model/provider readiness

    Operate
      allbert admin status
      allbert admin settings get KEY
      allbert admin channels
      allbert admin jobs
      allbert admin objectives
      allbert admin confirmations
      allbert admin home export|import

    Development and CI stay under mix.
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
