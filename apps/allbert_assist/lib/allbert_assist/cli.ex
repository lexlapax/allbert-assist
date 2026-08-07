defmodule AllbertAssist.CLI do
  @moduledoc """
  The unified `allbert <group> <command>` dispatcher (v0.62 M3).

  Entry is the release `:mod` Application start; `bin/allbert` passes argv here
  and the launcher halts on the returned code (the Next LS pattern). Every
  operator command resolves through `AllbertAssist.CLI.Commands` — a registered
  action via `Actions.Runner.run/3`, a bounded read, or a dispatcher built-in
  (serve/first-run/help/version/licenses). Developer/CI commands are absent from the
  binary surface (they stay Mix tasks). No dispatcher command reaches a store
  directly (the `cli-command-inventory-spine-map-001` eval-row invariant).

  `run/1` is pure (returns `{output, exit_code}`) so it is fully unit-testable;
  `main/1` prints and halts.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Ask
  alias AllbertAssist.CLI.Commands
  alias AllbertAssist.CLI.EntryPlan
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.Presentation
  alias AllbertAssist.Licenses
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Portability.Export
  alias AllbertAssist.Portability.Import
  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.Surfaces.ContextBuilder

  # v0.63 (operator-validation F1): a packaged CLI command boots the embedded runtime,
  # whose :info plugin/registration/migration logs would otherwise flood the operator's
  # terminal ahead of the command result. Default ordinary CLI commands to :warning
  # (the result stays on stdout via IO.puts; real problems still surface). The source
  # daemon uses :info so lifecycle signals remain observable without
  # Ecto bind-value debug logs. Override either source entry boundary with ALLBERT_LOG_LEVEL
  # (debug|info|notice|warning|error) for debugging.
  @doc false
  @spec configure_logging() :: :ok
  def configure_logging, do: configure_logging(:warning)

  @doc false
  @spec configure_daemon_logging() :: :ok
  def configure_daemon_logging do
    level = configured_log_level(:info)

    # `mix run` restarts Logger while starting applications. Persist the source
    # daemon level in all three Logger seams so that restart cannot restore
    # dev's :debug level and expose Ecto bind values.
    Application.put_env(:logger, :level, level)
    Logger.configure(level: level)
    _result = :logger.set_primary_config(:level, level)
    :ok
  rescue
    _error -> :ok
  end

  defp configure_logging(default_level) do
    Logger.configure(level: configured_log_level(default_level))
  rescue
    _error -> :ok
  end

  defp configured_log_level(default_level) do
    case System.get_env("ALLBERT_LOG_LEVEL") do
      level when level in ~w(debug info notice warning error) -> String.to_existing_atom(level)
      _absent_or_invalid -> default_level
    end
  end

  @doc false
  @spec run_attached([String.t()]) ::
          {String.t(), non_neg_integer()}
          | {:error, {:command_rejected, :product_not_ready}}
  def run_attached(argv) do
    plan = entry_plan(argv)

    case plan.disposition do
      :runtime_required ->
        with {:ok, epoch} <- EffectGuard.admit_ready(),
             result <- run_attached(argv, allbert_pack_epoch: epoch) do
          result
        else
          _error -> {:error, {:command_rejected, :product_not_ready}}
        end

      _runtime_free ->
        run_attached(argv, [])
    end
  end

  @doc false
  @spec run_attached([String.t()], keyword()) ::
          {String.t(), non_neg_integer()}
          | {:error, {:command_rejected, :product_not_ready}}
  def run_attached(argv, opts) do
    plan = entry_plan(argv)

    with :ok <- validate_local_options(opts),
         :ok <- validate_plan_epoch(plan, opts) do
      {_stream, output, code} = run_classified(plan, opts)
      {output, code}
    else
      {:error, reason} when reason in [:invalid_options, :product_not_ready, :stale_epoch] ->
        {:error, {:command_rejected, :product_not_ready}}
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

  def classify_attach({:error, {:command_rejected, :product_not_ready}}),
    do: {:error, "Allbert product is not ready; retry the command."}

  # Transport failed before any reply (:not_available/:closed/:timeout/
  # :econnrefused/:enoent/posix) — the command did NOT run on the daemon, so the
  # embedded fallback is safe.
  def classify_attach({:error, _reason}), do: :fallback

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

  @doc "Classify one invocation without starting applications or probing a provider."
  @spec entry_plan([String.t()]) :: EntryPlan.t()
  def entry_plan(argv) when is_list(argv) do
    case argv do
      ["licenses" | _args] ->
        %EntryPlan{
          schema_version: 1,
          argv: argv,
          disposition: :license_view,
          route: :licenses,
          first_run_state: :not_applicable
        }

      [] ->
        first_run_entry_plan()

      _other ->
        %EntryPlan{
          schema_version: 1,
          argv: argv,
          disposition: if(needs_runtime?(argv), do: :runtime_required, else: :runtime_free),
          route: :command,
          first_run_state: :not_applicable
        }
    end
  end

  @doc "Execute an already-classified invocation without attach or composition startup."
  @spec run_local(EntryPlan.t(), keyword()) ::
          {:stdout | :stderr, String.t(), non_neg_integer()}
  def run_local(%EntryPlan{} = plan, opts \\ []) do
    with :ok <- validate_local_options(opts),
         :ok <- validate_plan_epoch(plan, opts) do
      run_classified(plan, opts)
    else
      {:error, :invalid_options} ->
        {:stderr, "Invalid CLI readiness options.", 3}

      {:error, :product_not_ready} ->
        {:stderr, "Allbert product is not ready; retry the command.", 3}

      {:error, :stale_epoch} ->
        {:stderr, "Allbert product is not ready; retry the command.", 3}
    end
  end

  @doc "Compatibility dispatch: admit one current epoch for runtime-bearing commands."
  @spec run([String.t()]) :: {String.t(), non_neg_integer()}
  def run(argv) do
    plan = entry_plan(argv)

    opts =
      case plan.disposition do
        :runtime_required ->
          case EffectGuard.admit_ready() do
            {:ok, epoch} -> [allbert_pack_epoch: epoch]
            {:error, :product_not_ready} -> :unavailable
          end

        _runtime_free ->
          []
      end

    case opts do
      :unavailable ->
        {"Allbert product is not ready; retry the command.", 3}

      local_opts ->
        {_stream, output, code} = run_local(plan, local_opts)
        {output, code}
    end
  end

  defp first_run_entry_plan do
    state =
      case FirstRun.detect(first_model_state: :local_ready) do
        state when state in [:home_missing, :schema_incompatible, :onboarding_incomplete] -> state
        _post_onboarding -> :provider_probe_required
      end

    %EntryPlan{
      schema_version: 1,
      argv: [],
      disposition:
        if(state == :provider_probe_required, do: :runtime_required, else: :runtime_free),
      route: :first_run,
      first_run_state: state
    }
  end

  defp validate_local_options([]), do: :ok
  defp validate_local_options([{:allbert_pack_epoch, _epoch}]), do: :ok
  defp validate_local_options(_opts), do: {:error, :invalid_options}

  defp validate_plan_epoch(%EntryPlan{disposition: :runtime_required}, opts) do
    case Keyword.fetch(opts, :allbert_pack_epoch) do
      {:ok, epoch} -> EffectGuard.validate(epoch)
      :error -> {:error, :product_not_ready}
    end
  end

  defp validate_plan_epoch(%EntryPlan{}, []), do: :ok
  defp validate_plan_epoch(%EntryPlan{}, [_carrier]), do: {:error, :invalid_options}

  defp run_classified(%EntryPlan{route: :licenses, argv: ["licenses" | args]}, _opts) do
    case Licenses.view(args) do
      {:ok, %{output: output}} -> {:stdout, output, 0}
      {:error, %{message: message, exit_status: status}} -> {:stderr, message, status}
    end
  end

  defp run_classified(%EntryPlan{route: :first_run, first_run_state: state}, _opts)
       when state in [:home_missing, :schema_incompatible, :onboarding_incomplete] do
    {:stdout, first_run_state_message(state, :ready), 0}
  end

  defp run_classified(%EntryPlan{route: :first_run}, _opts) do
    {output, code} = first_run()
    {:stdout, output, code}
  end

  defp run_classified(%EntryPlan{route: :command, argv: argv}, opts) do
    {output, code} = legacy_dispatch(argv, opts)
    {:stdout, output, code}
  end

  defp legacy_dispatch(argv, opts) do
    case argv do
      ["--help"] -> {help(), 0}
      ["-h"] -> {help(), 0}
      ["help"] -> {help(), 0}
      ["--version"] -> {version(), 0}
      ["version"] -> {version(), 0}
      _other -> dispatch(argv, opts)
    end
  end

  # -- routing ---------------------------------------------------------------

  defp dispatch(argv, opts) do
    {path, rest} = resolve_path(argv)

    case Commands.lookup(path) do
      {:ok, {:action, name}} -> run_action(name, rest, opts)
      {:ok, {:read, mod, fun}} -> run_read(mod, fun, rest)
      {:ok, {:area, module}} -> run_area(module, rest, opts)
      {:ok, :builtin} -> run_builtin(path, rest, opts)
      {:ok, :mix_only} -> {mix_only_message(path), 2}
      :error -> unknown(path)
    end
  end

  # v0.62 M8.7: an area dispatcher owns its subcommands and returns
  # {output, exit_code} from a release-safe module shared with the Mix task.
  defp run_area(module, rest, opts) do
    context =
      %{surface: "cli", channel: :cli}
      |> ContextBuilder.cli_context()
      |> Map.merge(Map.new(opts))

    module.dispatch(rest, context)
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

  defp run_action(name, rest, opts) do
    context =
      %{surface: "cli", channel: :cli}
      |> ContextBuilder.cli_context()
      |> Map.merge(Map.new(opts))

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

  defp run_builtin(["serve"], _rest, _opts),
    do: {"`allbert serve` is handled by the release launcher.", 0}

  defp run_builtin(["ask"], rest, opts), do: Ask.run(rest, opts)

  defp run_builtin(["licenses"], rest, _opts) do
    case Licenses.view(rest) do
      {:ok, %{output: output}} -> {output, 0}
      {:error, %{message: message, exit_status: status}} -> {message, status}
    end
  end

  # `tui` is interactive (raw mode, blocks): the launcher overlay runs it in a
  # real TTY via `AllbertAssist.CLI.Tui.launch/0`. Reaching this pure clause
  # means it was invoked outside the launcher (e.g. `eval`), where a blocking
  # console cannot own the terminal — point the operator at the entry.
  defp run_builtin(["tui"], _rest, _opts),
    do: {"Run `allbert tui` from the installed binary (the launcher owns the TTY).", 0}

  defp run_builtin(["chat"], _rest, _opts), do: {chat_message(), 0}

  defp run_builtin(["admin", "home", "export"], rest, _opts) do
    opts = if out = out_flag(rest), do: [out: out], else: []

    case Export.build(opts) do
      {:ok, envelope} -> {render_result(%{message: "exported", envelope: summarize(envelope)}), 0}
      {:error, reason} -> {"export failed: #{inspect(reason)}", 1}
    end
  end

  defp run_builtin(["admin", "home", "import"], rest, _opts) do
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

  defp run_builtin(_path, _rest, _opts), do: {help(), 0}

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
    details = FirstRun.detect_details()
    state = details.state
    projection = readiness_projection(details)
    readiness = projection.direct_answer_readiness

    {first_run_message(state, projection, readiness), 0}
  end

  defp first_run_message(state, projection, readiness) do
    if consent_disabled?(projection) and state not in [:home_missing, :schema_incompatible],
      do: disabled_model_message(projection),
      else: first_run_state_message(state, readiness)
  end

  defp first_run_state_message(:home_missing, _readiness) do
    "Allbert Home is not set up yet. Start the installed service, then open the web workspace. " <>
      "Use `allbert admin service install --dry-run` to preview service setup, or `allbert serve --open` as a repair fallback."
  end

  defp first_run_state_message(:schema_incompatible, _readiness),
    do: "Allbert Home needs a schema upgrade before it can start. See the upgrade guide."

  defp first_run_state_message(:onboarding_incomplete, :ready),
    do:
      "Onboarding is optional. Open the web workspace or run `allbert onboard` to customize Allbert."

  defp first_run_state_message(:onboarding_incomplete, readiness),
    do: "Onboarding is optional. " <> model_repair_message(readiness)

  defp first_run_state_message(:first_model_not_ready, :ready),
    do:
      "DirectAnswer is ready with its selected profile. The optional global starter profile is unavailable; open Models to review it."

  defp first_run_state_message(:first_model_not_ready, readiness),
    do: model_repair_message(readiness)

  defp first_run_state_message(:profile_unreviewed, readiness),
    do: profile_review_message(readiness)

  defp first_run_state_message(:product_ready, :ready),
    do: "Allbert is ready. Open the web workspace, or run `allbert --help`."

  defp first_run_state_message(:product_ready, readiness),
    do: model_repair_message(readiness)

  defp consent_disabled?(%{enablement_result: %{state: :sticky_disabled}}), do: true
  defp consent_disabled?(_projection), do: false

  defp disabled_model_message(%{enablement_result: result}) do
    presentation = Presentation.for(result, :cli)

    "#{presentation.message} Open Models or run " <>
      "`allbert admin settings set intent.direct_answer_model_enabled true` to re-enable; " <>
      "onboarding remains optional."
  end

  defp model_repair_message(readiness) do
    guidance = Onboarding.model_guidance_for(readiness, :quickstart)

    prefix =
      if readiness == :needs_selection,
        do: "DirectAnswer is not ready.",
        else: "No usable model yet."

    "#{prefix} #{guidance.headline} Next: #{guidance.next_action} " <>
      "Open the Models panel in the web workspace#{repair_command_suffix(guidance.action)}."
  end

  defp profile_review_message(:ready) do
    "A profile is pending review. Open the web workspace onboarding panel, or run `allbert onboard`."
  end

  defp profile_review_message(readiness) do
    "A profile is pending review. " <> model_repair_message(readiness)
  end

  defp readiness_projection(%{first_model_state: nil}), do: FirstRun.readiness_projection()

  defp readiness_projection(%{first_model_state: model_state}) do
    FirstRun.readiness_projection(model_state: model_state)
  end

  defp repair_command_suffix(:install_runtime),
    do: ", or run `allbert onboard install-runtime --authorize`"

  defp repair_command_suffix(:pull_model),
    do: ", or run `allbert onboard pull-model --authorize`"

  defp repair_command_suffix(:select_model),
    do: ", or run `allbert admin models catalog direct_answer`"

  defp repair_command_suffix(_action), do: ", or run `allbert onboard`"

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
      allbert search QUERY     Search currently authorized conversation history

    Set up
      allbert                  Resume setup or open the product
      allbert onboard          Guided first-run wizard (QuickStart/Advanced)
      allbert admin onboarding Review setup state
      allbert admin models     Check model/provider readiness
      allbert admin vault      Show the secret-vault tier

    Inspect
      allbert licenses         Show packaged component and license evidence

    Operate (each `admin <area>` has its own subcommands; run one for usage)
      allbert admin status | health | trace | registry | events
      allbert admin settings | channels | jobs | objectives | confirmations
      allbert admin threads | sessions | memory | skills | plugins | apps
      allbert admin mcp | intent | workspace | workflows | plan | tools
      allbert admin resources | marketplace | packages | external | exec
      allbert admin voice | trust | self-improvement | public_protocol
      allbert admin service status|install|uninstall | db list-backups|restore | secrets migrate | home export|import

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
