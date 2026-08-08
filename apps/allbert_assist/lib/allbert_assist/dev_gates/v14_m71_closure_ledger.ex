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

  # External library dependencies the relocated kernel will carry. Each is a
  # real call or struct match in a target, not a documentation mention, and each
  # becomes a declared dependency of `apps/allbert_kernel/mix.exs` under the R2
  # move manifest.
  @admitted_libraries %{
    Exqlite.Sqlite3 => :exqlite,
    Jason => :jason,
    Jido.Action => :jido_action,
    Jido.Action.Schema => :jido_action,
    Jido.Signal => :jido_signal
  }

  # Elixir and OTP modules need no admission. Anything capitalized that is not
  # an Allbert module, an admitted library, or one of these is a finding.
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
            Kernel,
            KeyError,
            Keyword,
            List,
            Macro,
            Map,
            MapSet,
            Module,
            NaiveDateTime,
            Path,
            Process,
            Regex,
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

  @doc "The external libraries the relocated kernel is admitted to depend on."
  @spec admitted_libraries() :: %{module() => atom()}
  def admitted_libraries, do: @admitted_libraries

  @doc "The OTP applications `apps/allbert_kernel/mix.exs` must declare at M8."
  @spec admitted_applications() :: [atom()]
  def admitted_applications,
    do: @admitted_libraries |> Map.values() |> Enum.uniq() |> Enum.sort()

  @doc """
  Resolve every reference in every relocation target and report what does not close.

  An empty list is the M7.1 acceptance condition: the future kernel closes over
  its own roster, `allbert_kernel`, admitted libraries, and Elixir/OTP.
  """
  @spec findings() :: {:ok, [finding()]} | {:error, term()}
  def findings do
    with {:ok, kernel_modules} <- kernel_modules(),
         {:ok, roster_modules} <- roster_modules() do
      allowed = MapSet.union(kernel_modules, roster_modules)

      findings =
        Enum.flat_map(roster(), fn {path, concern} ->
          path
          |> references()
          |> Enum.reject(&(MapSet.member?(allowed, &1) or admitted?(&1)))
          |> Enum.map(&%{path: path, concern: concern, module: &1, reason: classify_finding(&1)})
        end)

      {:ok, Enum.sort_by(findings, &{&1.path, Atom.to_string(&1.module)})}
    end
  end

  @doc "A stable ledger record for evidence, independent of source line numbers."
  @spec ledger() :: {:ok, map()} | {:error, term()}
  def ledger do
    with {:ok, findings} <- findings() do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "roster_size" => map_size(@roster),
         "concerns" =>
           @roster
           |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
           |> Map.new(fn {concern, paths} ->
             {Atom.to_string(concern), Enum.sort(paths)}
           end),
         "admitted_applications" => Enum.map(admitted_applications(), &Atom.to_string/1),
         "findings" =>
           Enum.map(findings, fn finding ->
             %{
               "path" => finding.path,
               "concern" => Atom.to_string(finding.concern),
               "module" => inspect(finding.module),
               "reason" => Atom.to_string(finding.reason)
             }
           end)
       }}
    end
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

  defp admitted?(module),
    do: Map.has_key?(@admitted_libraries, module) or MapSet.member?(@stdlib, module)

  defp kernel_modules do
    @repo_root
    |> Path.join(@kernel_source_glob)
    |> Path.wildcard()
    |> Enum.flat_map(&(&1 |> quoted_absolute!() |> defined_modules()))
    |> MapSet.new()
    |> then(&{:ok, &1})
  end

  defp roster_modules do
    @roster
    |> Map.keys()
    |> Enum.flat_map(&(&1 |> quoted!() |> defined_modules()))
    |> MapSet.new()
    |> then(&{:ok, &1})
  end

  defp quoted!(relative_path), do: quoted_absolute!(Path.join(@repo_root, relative_path))

  defp quoted_absolute!(path), do: path |> File.read!() |> Code.string_to_quoted!()

  defp defined_modules(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _alias_meta, parts} | _rest]} = node, acc ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, [Module.concat(parts) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

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
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, args} = node, table -> {node, put_aliases(table, args)}
        node, table -> {node, table}
      end)

    table
  end

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
    case Enum.find_value(rest, fn
           opts when is_list(opts) ->
             case Keyword.get(opts, :as) do
               {:__aliases__, _meta, [binding]} when is_atom(binding) -> binding
               _other -> nil
             end

           _other ->
             nil
         end) do
      nil -> List.last(parts)
      binding -> binding
    end
  end

  defp resolve([head | tail], table) do
    case Map.fetch(table, head) do
      {:ok, expansion} -> Module.concat(expansion ++ tail)
      :error -> Module.concat([head | tail])
    end
  end
end
