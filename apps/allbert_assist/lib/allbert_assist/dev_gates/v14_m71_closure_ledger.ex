defmodule AllbertAssist.DevGates.V14M71ClosureLedger do
  @moduledoc """
  Deterministic v1.4 M7.1 proof that the M8 relocation roster closes.

  ADR 0098 §2 makes "the kernel must not depend on a pack" a build failure once
  the modules move. Before they move there is no compiler to enforce it, so this
  gate is the enforcement: it resolves every module reference in every
  relocation target and requires each one to land in the roster itself, in
  `allbert_kernel`, or in an explicitly admitted external library.

  ## Why this is not a `mix xref` wrapper

  Xref reports file-to-file edges for compiled project sources. That misses
  three things this proof needs. A module atom used only as an
  `Application.get_env/2` key is an edge with no call behind it — that is how
  five of `Paths`'s residual references hid. External library and OTP
  dependencies are not project files, so xref never shows the `Exqlite`, `Jido`,
  and `Jason` admissions the kernel application will have to declare. And an
  alias introduced with `as:` or a multi-alias resolves to a different module
  than the source token suggests, so a text scan reports the wrong answer in
  both directions.

  This gate therefore reads the AST, builds each file's alias table including
  `as:` and `A.{B, C}` forms, and resolves every reference through it. The
  library admissions below are the exact set the kernel's `mix.exs` must declare
  at M8; a new one appearing here is a dependency decision that has to be made
  deliberately rather than discovered after the move.
  """

  @schema_version 1
  @repo_root Path.expand("../../../../..", __DIR__)

  @kernel_source_glob "apps/allbert_kernel/lib/**/*.ex"
  @kernel_test_glob "apps/allbert_kernel/test/**/*.exs"

  # The M8 relocation roster, frozen at M7.1. Nineteen concern modules plus the
  # six companion-substrate modules admitted by closure.
  @roster %{
    # Concern 1 — Home and Identity. WriterLock.Holder is deliberately absent:
    # it is a daemon-mode supervision child and stays a residual startup host.
    "apps/allbert_assist/lib/allbert_assist/paths.ex" => :home_identity,
    "apps/allbert_assist/lib/allbert_assist/config_context.ex" => :home_identity,
    "apps/allbert_assist/lib/allbert_assist/runtime/writer_lock.ex" => :home_identity,

    # Concern 3 — Security Central.
    "apps/allbert_assist/lib/allbert_assist/security.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/audit.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/context.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/decision.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/policy.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/redactor.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/review.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/risk.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/security/status.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/external/http_policy.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/external/request_spec.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/maps.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/validation.ex" => :security_central,
    "apps/allbert_assist/lib/allbert_assist/runtime/safe_term.ex" => :security_central,

    # Concern 4 — Capability Plane.
    "apps/allbert_assist/lib/allbert_assist/action.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/actions/capability.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/actions/param_contract.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/actions/registry.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/actions/runner.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/actions/snapshot_catalog.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/runtime/response.ex" => :capability_plane,
    "apps/allbert_assist/lib/allbert_assist/registry_context.ex" => :capability_plane
  }

  # Owning tests that do not relocate at all, with the reason each stays.
  #
  # M7.2's rule is that a row which cannot be made kernel-pure without changing
  # what it asserts stays with the residual. Applied to every row of a file, the
  # file stays. These four are integration suites by subject: they exercise
  # kernel modules, but proving them needs the residual registry, dynamic
  # overlay, signal bus, and database. Stubbing that machinery would leave each
  # row asserting the stub.
  #
  # After extraction this is the steady state ADR 0098 describes — a pack tests
  # against the kernel — but it is recorded here rather than left implicit,
  # because the consequence is that the Capability Plane relocates with no
  # kernel-owned test of its own.
  @residual_owned_tests %{
    "apps/allbert_assist/test/allbert_assist/actions/param_contract_test.exs" =>
      "DataCase-bound; every row drives Runner through isolated registries and the confirmed overlay",
    "apps/allbert_assist/test/allbert_assist/actions/registry_test.exs" =>
      "asserts the shipped action catalog and App/Plugin registration lifecycle, both residual subjects",
    "apps/allbert_assist/test/allbert_assist/actions/runner_test.exs" =>
      "exercises registry resolution, plugin actions, and overlay registration end to end",
    "apps/allbert_assist/test/allbert_assist/registry_context_test.exs" =>
      "its subject is registry isolation across App/Plugin/extension registries and the signal bus"
  }

  # Suites that prove a whole concern rather than one module. They relocate with
  # the concern; no per-module row claims them as its dedicated owner.
  @shared_tests [
    security_central: [
      "apps/allbert_assist/test/allbert_assist/security/channel_inbound_policy_test.exs",
      "apps/allbert_assist/test/allbert_assist/security/permission_gate_test.exs",
      "apps/allbert_assist/test/allbert_assist/security/public_surface_policy_test.exs",
      "apps/allbert_assist/test/allbert_assist/security/security_central_test.exs"
    ]
  ]

  # External library dependencies the relocated kernel will carry. Each is a
  # real call or struct match in a target, not a documentation mention, and each
  # becomes a declared dependency of `apps/allbert_kernel/mix.exs` under the R2
  # move manifest.
  @admitted_libraries %{
    Exqlite.Sqlite3 => :exqlite,
    Jason => :jason,
    Jido.Action => :jido_action,
    Jido.Action.Schema => :jido_action,
    Jido.Signal => :jido_signal,
    Jido.Signal.Bus => :jido_signal
  }

  # Elixir and OTP modules need no admission. Anything capitalized that is not
  # an Allbert module, an admitted library, or one of these is a finding.
  # Test-framework modules a kernel test file may name. They are not capability
  # edges; admitting them here keeps the kernel test closure honest about what
  # else a split half is allowed to reach.
  @test_framework MapSet.new([
                    ExUnit,
                    ExUnit.Assertions,
                    ExUnit.Callbacks,
                    ExUnit.Case,
                    ExUnit.CaptureLog,
                    ExUnit.CaptureIO
                  ])

  @stdlib MapSet.new([
            Access,
            Application,
            ArgumentError,
            Atom,
            Base,
            Bitwise,
            Code,
            DateTime,
            Enum,
            Exception,
            File,
            Float,
            Function,
            GenServer,
            Integer,
            IO,
            Kernel,
            KeyError,
            Keyword,
            List,
            Logger,
            Macro,
            Map,
            MapSet,
            Module,
            NaiveDateTime,
            Path,
            Process,
            Regex,
            Registry,
            Stream,
            String,
            String.Chars,
            Supervisor,
            System,
            Task,
            Tuple,
            URI,
            Version
          ])

  @type finding :: %{
          path: String.t(),
          concern: atom(),
          module: module(),
          reason: :residual_dependency | :unadmitted_library
        }

  @doc "The frozen roster as `{repository-relative path, concern}` pairs."
  @spec roster() :: [{String.t(), atom()}]
  def roster, do: @roster |> Enum.sort_by(&elem(&1, 0))

  @typedoc "A library module a relocation target is admitted to reference."
  @type admitted_library ::
          Exqlite.Sqlite3
          | Jason
          | Jido.Action
          | Jido.Action.Schema
          | Jido.Signal
          | Jido.Signal.Bus

  @typedoc "An OTP application the relocated kernel will declare."
  @type admitted_application :: :exqlite | :jason | :jido_action | :jido_signal

  @doc "The external libraries the relocated kernel is admitted to depend on."
  @spec admitted_libraries() :: %{admitted_library() => admitted_application()}
  def admitted_libraries, do: Map.new(@admitted_libraries)

  @doc "The OTP applications `apps/allbert_kernel/mix.exs` must declare at M8."
  @spec admitted_applications() :: [admitted_application()]
  def admitted_applications,
    do: @admitted_libraries |> Map.values() |> Enum.uniq() |> Enum.sort()

  @doc """
  Resolve every reference in every relocation target and report what does not close.

  An empty list is the M7.1 acceptance condition: the future kernel closes over
  its own roster, `allbert_kernel`, admitted libraries, and Elixir/OTP.
  """
  @spec findings() :: {:ok, [finding()]}
  def findings do
    allowed = MapSet.union(kernel_modules(), roster_modules())

    findings =
      Enum.flat_map(roster(), fn {path, concern} ->
        path
        |> references()
        |> Enum.reject(&(MapSet.member?(allowed, &1) or admitted?(&1)))
        |> Enum.map(&%{path: path, concern: concern, module: &1, reason: classify_finding(&1)})
      end) ++ relocating_test_findings(allowed) ++ kernel_test_findings(allowed)

    {:ok, Enum.sort_by(findings, &{&1.path, Atom.to_string(&1.module)})}
  end

  # M7.2 splits owning tests in place, because a kernel-destined half cannot
  # live under `apps/allbert_kernel/test` until M8 moves the modules it
  # exercises — the kernel does not depend on the pack, so it could not compile
  # there. The half that will move therefore keeps the original path and is
  # checked here; the half that stays becomes a separate residual file that
  # this gate does not constrain.
  @doc """
  The M7.2 split backlog: owning tests that do not close.

  Empty since the split completed, at which point these rows folded into
  `findings/0` — the two checks are now one, and this remains as the narrower
  view for diagnosing which owning test regressed.
  """
  @spec split_backlog() :: {:ok, [finding()]}
  def split_backlog do
    allowed = MapSet.union(kernel_modules(), roster_modules())
    {:ok, Enum.sort_by(relocating_test_findings(allowed), &{&1.path, Atom.to_string(&1.module)})}
  end

  defp relocating_test_findings(allowed) do
    Enum.flat_map(relocating_tests(), fn path ->
      local = path |> quoted!() |> defined_modules()

      path
      |> references()
      |> Enum.reject(
        &(MapSet.member?(allowed, &1) or admitted?(&1) or
            MapSet.member?(@test_framework, &1) or local?(&1, local))
      )
      |> Enum.map(
        &%{path: path, concern: :relocating_test, module: &1, reason: classify_finding(&1)}
      )
    end)
  end

  # A test that reaches a residual fixture breaks the invariant in the test
  # dimension rather than the compile one, which is exactly the failure M7.2
  # exists to prevent. Checking kernel test files here means a split half that
  # did not actually close fails now instead of at M8.
  defp kernel_test_findings(allowed) do
    @repo_root
    |> Path.join(@kernel_test_glob)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      # A test file's own stubs, its test module, and anything nested under
      # them are local scaffolding, not dependencies.
      local = path |> quoted!() |> defined_modules()

      path
      |> references()
      |> Enum.reject(
        &(MapSet.member?(allowed, &1) or admitted?(&1) or
            MapSet.member?(@test_framework, &1) or local?(&1, local))
      )
      |> Enum.map(&%{path: path, concern: :kernel_test, module: &1, reason: classify_finding(&1)})
    end)
  end

  defp local?(module, local) do
    name = Atom.to_string(module)

    Enum.any?(local, fn defined ->
      defined_name = Atom.to_string(defined)

      module == defined or String.starts_with?(defined_name, name <> ".") or
        String.starts_with?(name, defined_name <> ".")
    end)
  end

  @doc "A stable ledger record for evidence, independent of source line numbers."
  @spec ledger() :: {:ok, map()}
  def ledger do
    {:ok, findings} = findings()

    record = [
      {"schema_version", @schema_version},
      {"roster_size", map_size(@roster)},
      {"concerns", concern_index()},
      {"admitted_applications", Enum.map(admitted_applications(), &Atom.to_string/1)},
      {"findings", Enum.map(findings, &finding_row/1)}
    ]

    {:ok, Map.new(record)}
  end

  defp concern_index do
    @roster
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Map.new(fn {concern, paths} -> {Atom.to_string(concern), Enum.sort(paths)} end)
  end

  defp finding_row(finding) do
    Map.new([
      {"path", finding.path},
      {"concern", Atom.to_string(finding.concern)},
      {"module", inspect(finding.module)},
      {"reason", Atom.to_string(finding.reason)}
    ])
  end

  @doc """
  The R2 move manifest M8 consumes without changing a byte.

  Every row carries the pre-move content digest of its source and of its owning
  test. M8's acceptance is that each relocated file still hashes to the value
  frozen here: a relocation that changes content is not a relocation.

  Destinations are mechanical — the same path under `apps/allbert_kernel`,
  because BEAM module names are independent of application names and nothing is
  renamed. A module with no dedicated owning test carries an empty test row and
  is covered by its concern's shared tests below.
  """
  @spec move_manifest() :: {:ok, [map()]}
  def move_manifest do
    rows =
      Enum.map(roster(), fn {source, concern} ->
        test_source = owning_test(source)

        Map.new([
          {"concern", Atom.to_string(concern)},
          {"module", source |> module_for_source() |> inspect()},
          {"source", source},
          {"destination", destination(source)},
          {"source_sha256", digest(source)},
          {"test_source", test_source || ""},
          {"test_destination", (test_source && destination(test_source)) || ""},
          {"test_sha256", (test_source && digest(test_source)) || ""},
          {"disposition", "move"}
        ])
      end)

    {:ok, rows}
  end

  @doc """
  Tests that cover a whole concern rather than one module.

  They move with their concern. Recording them separately keeps the per-module
  rows honest: four Security Central suites exercise the plane as a unit, and
  claiming any one of them as a single module's owner would misstate what
  proves that module.
  """
  @spec shared_tests() :: %{atom() => [String.t()]}
  def shared_tests, do: Map.new(@shared_tests)

  @doc "Every test file that relocates, dedicated and shared, sorted."
  @spec relocating_tests() :: [String.t()]
  def relocating_tests do
    dedicated = @roster |> Map.keys() |> Enum.map(&owning_test/1) |> Enum.reject(&is_nil/1)
    shared = @shared_tests |> Enum.flat_map(&elem(&1, 1))

    (dedicated ++ shared) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Owning tests that stay with the residual, mapped to the reason each stays."
  @spec residual_owned_tests() :: %{String.t() => String.t()}
  def residual_owned_tests, do: Map.new(@residual_owned_tests)

  defp owning_test(source) do
    candidate =
      source
      |> String.replace_prefix("apps/allbert_assist/lib/allbert_assist/", "")
      |> String.replace_suffix(".ex", "_test.exs")
      |> then(&Path.join("apps/allbert_assist/test/allbert_assist", &1))

    cond do
      Map.has_key?(@residual_owned_tests, candidate) -> nil
      File.exists?(Path.join(@repo_root, candidate)) -> candidate
      true -> nil
    end
  end

  defp destination(source) do
    String.replace_prefix(source, "apps/allbert_assist/", "apps/allbert_kernel/")
  end

  defp digest(relative_path) do
    @repo_root
    |> Path.join(relative_path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp module_for_source(source) do
    source |> quoted!() |> defined_modules() |> List.last()
  end

  @doc "Every module a relocation target references, with aliases resolved."
  @spec references(String.t()) :: [module()]
  def references(path) do
    ast = quoted!(path)
    table = alias_table(ast)

    ast
    |> raw_references()
    |> Enum.map(&resolve(&1, table))
    |> Enum.uniq()
  end

  defp classify_finding(module) do
    if String.starts_with?(Atom.to_string(module), "Elixir.AllbertAssist"),
      do: :residual_dependency,
      else: :unadmitted_library
  end

  # One deliberate negative fixture: the binder's rejection row needs a module
  # that is guaranteed not to load, and a module that exists nowhere cannot be
  # a residual dependency. Listing it keeps the exception greppable rather than
  # letting unresolvable names pass generally, which would hide a typo.
  @absent_fixtures MapSet.new([AllbertAssist.Kernel.NoSuchProvider])

  defp admitted?(module) do
    Map.has_key?(@admitted_libraries, module) or MapSet.member?(@stdlib, module) or
      MapSet.member?(@absent_fixtures, module)
  end

  defp kernel_modules do
    @repo_root
    |> Path.join(@kernel_source_glob)
    |> Path.wildcard()
    |> Enum.flat_map(&(&1 |> quoted_absolute!() |> defined_modules()))
    |> MapSet.new()
  end

  defp roster_modules do
    @roster
    |> Map.keys()
    |> Enum.flat_map(&(&1 |> quoted!() |> defined_modules()))
    |> MapSet.new()
  end

  defp quoted!(relative_path), do: quoted_absolute!(Path.join(@repo_root, relative_path))

  defp quoted_absolute!(path), do: path |> File.read!() |> Code.string_to_quoted!()

  # A nested `defmodule Input` inside `AllbertAssist.Pack.RowSchemas` defines
  # `AllbertAssist.Pack.RowSchemas.Input`, not `Input`. Carrying the enclosing
  # prefix is what makes the kernel test closure recognize those as local.
  defp defined_modules(ast), do: defined_modules(ast, [])

  defp defined_modules({:defmodule, _meta, [{:__aliases__, _am, parts} | rest]}, prefix)
       when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      nested = prefix ++ parts
      [Module.concat(nested) | defined_modules(rest, nested)]
    else
      defined_modules(rest, prefix)
    end
  end

  defp defined_modules({_form, _meta, args}, prefix), do: defined_modules(args, prefix)
  defp defined_modules({left, right}, prefix), do: defined_modules([left, right], prefix)

  defp defined_modules(list, prefix) when is_list(list),
    do: Enum.flat_map(list, &defined_modules(&1, prefix))

  defp defined_modules(_other, _prefix), do: []

  # Collect every alias segment list in the file, expanding `A.{B, C}` so a
  # multi-alias contributes `A.B` and `A.C` rather than a bare `B` and `C` and a
  # meaningless `A` prefix.
  defp raw_references(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [{:__aliases__, _base_meta, base}, :{}]}, _meta, children}, acc
        when is_list(base) ->
          # Replace the node so the walk does not also descend into the base
          # prefix and report `A` as a module of its own.
          {:__multi_alias_collected__, expand_multi(base, children) ++ acc}

        {:__aliases__, _meta, parts} = node, acc ->
          if Enum.all?(parts, &is_atom/1), do: {node, [parts | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.uniq() |> Enum.reverse()
  end

  defp expand_multi(base, children) do
    Enum.flat_map(children, fn
      {:__aliases__, _meta, parts} when is_list(parts) ->
        if Enum.all?(parts, &is_atom/1), do: [base ++ parts], else: []

      _other ->
        []
    end)
  end

  # `alias A.B.C` binds `C`; `alias A.B, as: X` binds `X`; `alias A.{B, C}`
  # binds both. Resolving through this table is what stops a renamed alias from
  # reading as a different module than it is.
  defp alias_table(ast) do
    {_ast, table} =
      Macro.prewalk(ast, nested_module_aliases(ast), fn
        {:alias, _meta, args} = node, table -> {node, put_aliases(table, args)}
        node, table -> {node, table}
      end)

    table
  end

  # Elixir auto-aliases a nested module inside its parent, so a test stub
  # `defmodule ReadyBarrier` written inside `FooTest` is referenced as
  # `ReadyBarrier` but is `FooTest.ReadyBarrier`. Without this the resolver
  # reports a bare `Elixir.ReadyBarrier` that exists nowhere.
  defp nested_module_aliases(ast) do
    ast
    |> defined_module_parts([])
    |> Map.new(fn parts -> {List.last(parts), parts} end)
  end

  defp defined_module_parts({:defmodule, _meta, [{:__aliases__, _am, parts} | rest]}, prefix)
       when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      nested = prefix ++ parts
      [nested | defined_module_parts(rest, nested)]
    else
      defined_module_parts(rest, prefix)
    end
  end

  defp defined_module_parts({_form, _meta, args}, prefix), do: defined_module_parts(args, prefix)

  defp defined_module_parts({left, right}, prefix),
    do: defined_module_parts([left, right], prefix)

  defp defined_module_parts(list, prefix) when is_list(list),
    do: Enum.flat_map(list, &defined_module_parts(&1, prefix))

  defp defined_module_parts(_other, _prefix), do: []

  defp put_aliases(table, [{{:., _dot, [{:__aliases__, _bm, base}, :{}]}, _m, children} | _rest])
       when is_list(base) do
    base
    |> expand_multi(children)
    |> Enum.reduce(table, fn parts, acc -> Map.put(acc, List.last(parts), parts) end)
  end

  defp put_aliases(table, [{:__aliases__, _meta, parts} | rest]) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Map.put(table, alias_binding(parts, rest), parts)
    else
      table
    end
  end

  defp put_aliases(table, _args), do: table

  defp alias_binding(parts, rest) do
    Enum.find_value(rest, List.last(parts), &as_binding/1)
  end

  defp as_binding(opts) when is_list(opts), do: as_binding(Keyword.get(opts, :as))
  defp as_binding({:__aliases__, _meta, [binding]}) when is_atom(binding), do: binding
  defp as_binding(_other), do: nil

  defp resolve([head | tail], table) do
    case Map.fetch(table, head) do
      {:ok, expansion} -> Module.concat(expansion ++ tail)
      :error -> Module.concat([head | tail])
    end
  end
end
