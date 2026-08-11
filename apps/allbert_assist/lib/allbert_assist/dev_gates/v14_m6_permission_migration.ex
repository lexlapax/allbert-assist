defmodule AllbertAssist.DevGates.V14M6PermissionMigration do
  @moduledoc """
  Deterministic v1.4 M6 proof for the direct permission-facade retirement.

  The frozen fixture records the predecessor call sites without source line
  numbers. The live check requires the same path, module/function clause,
  lexical call order, caller family, and normalized argument expressions while
  admitting only the reviewed Security Central, runtime response, and policy
  vocabulary targets.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @schema_version 1
  @normalization "v14_m6_permission_migration_v1"
  @predecessor_sha "7ae566f59f74cb51d8aed77e2f51c3df80172e1f"
  @repo_root Path.expand("../../../../..", __DIR__)
  @source_globs ["apps/*/lib/**/*.ex", "plugins/*/lib/**/*.ex"]

  @predecessor_owner "AllbertAssist.Security." <> "Permission" <> "Gate"
  @predecessor_targets %{
    {@predecessor_owner, :authorize, 2} => {"authorize", "AllbertAssist.Security.authorize/2"},
    {@predecessor_owner, :allowed?, 1} => {"allowed", "AllbertAssist.Security.allowed?/1"},
    {@predecessor_owner, :response_status, 1} =>
      {"response_status", "AllbertAssist.Runtime.Response.permission_status/1"},
    {@predecessor_owner, :permission_classes, 0} =>
      {"permission_classes", "AllbertAssist.Security.Policy.permission_classes/0"},
    {@predecessor_owner, :approval_modes, 0} =>
      {"approval_modes", "AllbertAssist.Security.Policy.approval_modes/0"},
    {@predecessor_owner, :approval_mode, 1} =>
      {"approval_mode", "AllbertAssist.Security.Policy.approval_mode/1"},
    {@predecessor_owner, :coding_tiers, 0} =>
      {"coding_tiers", "AllbertAssist.Security.Policy.coding_tiers/0"},
    {@predecessor_owner, :coding_tier, 1} =>
      {"coding_tier", "AllbertAssist.Security.Policy.coding_tier/1"}
  }

  @current_targets %{
    {"AllbertAssist.Security", :authorize, 2} =>
      {"authorize", "AllbertAssist.Security.authorize/2"},
    {"AllbertAssist.Security", :allowed?, 1} => {"allowed", "AllbertAssist.Security.allowed?/1"},
    {"AllbertAssist.Runtime.Response", :permission_status, 1} =>
      {"response_status", "AllbertAssist.Runtime.Response.permission_status/1"},
    {"AllbertAssist.Security.Policy", :permission_classes, 0} =>
      {"permission_classes", "AllbertAssist.Security.Policy.permission_classes/0"},
    {"AllbertAssist.Security.Policy", :approval_modes, 0} =>
      {"approval_modes", "AllbertAssist.Security.Policy.approval_modes/0"},
    {"AllbertAssist.Security.Policy", :approval_mode, 1} =>
      {"approval_mode", "AllbertAssist.Security.Policy.approval_mode/1"},
    {"AllbertAssist.Security.Policy", :coding_tiers, 0} =>
      {"coding_tiers", "AllbertAssist.Security.Policy.coding_tiers/0"},
    {"AllbertAssist.Security.Policy", :coding_tier, 1} =>
      {"coding_tier", "AllbertAssist.Security.Policy.coding_tier/1"}
  }

  @non_action_paths %{
    "apps/allbert_assist/lib/allbert_assist/agents/intent_agent.ex" => "intent_agent",
    "apps/allbert_assist/lib/allbert_assist/coding/bash_spec.ex" => "coding_bash_spec",
    "apps/allbert_assist/lib/allbert_assist/coding/session_guard.ex" => "coding_session_guard",
    "apps/allbert_assist/lib/allbert_assist/plan_build.ex" => "plan_build",
    "apps/allbert_assist/lib/allbert_assist/plan_build/runtime.ex" => "plan_build",
    "apps/allbert_assist/lib/allbert_assist/resources/grants.ex" => "resource_grants",
    "plugins/allbert.browser/lib/allbert_browser/actions.ex" => "allbert_browser_helper",
    "apps/allbert_notes_files/lib/allbert_notes_files/actions.ex" => "allbert_notes_files_helper",
    "plugins/stocksage/lib/stocksage/actions.ex" => "stocksage_helper"
  }

  @doc "Return the repository-owned predecessor caller fixture path."
  @spec fixture_path() :: Path.t()
  def fixture_path do
    Path.expand(
      "../../../test/fixtures/v1.4/m6_permission_callers.json.zlib.b64",
      __DIR__
    )
  end

  @doc "Load and self-validate the immutable predecessor caller fixture."
  @spec load_fixture!() :: map()
  def load_fixture! do
    fixture =
      case fixture_path()
           |> File.read!()
           |> String.trim()
           |> Base.decode64!()
           |> :zlib.uncompress()
           |> Jason.decode!() do
        %{} = decoded -> decoded
        _other -> raise "invalid v1.4 M6 permission caller fixture"
      end

    valid? =
      fixture["schema_version"] == @schema_version and
        fixture["normalization"] == @normalization and
        get_in(fixture, ["provenance", "source_sha"]) == @predecessor_sha and
        is_list(fixture["files"]) and
        fixture["counts"] == counts_from_files(fixture["files"]) and
        fixture["non_action_families"] == non_action_families_from_files(fixture["files"]) and
        get_in(fixture, ["digests", "files_sha256"]) == digest(fixture["files"])

    if valid?, do: fixture, else: raise("invalid v1.4 M6 permission caller fixture")
  end

  @doc "Fail unless every predecessor call has exactly the approved live target."
  @spec check!() :: :ok
  def check! do
    fixture = load_fixture!()
    paths = MapSet.new(fixture["files"], & &1["source_path"])
    live = current_inventory(paths)

    expected = Map.take(fixture, ["counts", "non_action_families", "files"])
    actual = Map.take(live, ["counts", "non_action_families", "files"])

    if expected == actual and
         get_in(fixture, ["digests", "expected_rows_sha256"]) ==
           get_in(live, ["digests", "expected_rows_sha256"]) do
      :ok
    else
      frozen_files = Map.new(fixture["files"], &{&1["source_path"], &1})
      live_files = Map.new(live["files"], &{&1["source_path"], &1})

      missing = Map.keys(frozen_files) -- Map.keys(live_files)
      unexpected = Map.keys(live_files) -- Map.keys(frozen_files)

      changed =
        (Map.keys(frozen_files) -- missing)
        |> Enum.filter(&(Map.get(frozen_files, &1) != Map.get(live_files, &1)))
        |> Enum.sort()

      raise "v1.4 M6 permission migration drift: " <>
              "missing_files=#{inspect(Enum.sort(missing))} " <>
              "unexpected_files=#{inspect(Enum.sort(unexpected))} " <>
              "changed_files=#{inspect(changed)}"
    end
  end

  @doc "Discover the current production caller inventory."
  def current_inventory do
    fixture = load_fixture!()
    paths = MapSet.new(fixture["files"], & &1["source_path"])
    current_inventory(paths)
  end

  @doc "Build a predecessor fixture snapshot from path/source pairs."
  @spec predecessor_fixture([{Path.t(), String.t()}]) :: map()
  def predecessor_fixture(sources) when is_list(sources) do
    rows =
      sources
      |> Enum.flat_map(fn {path, source} -> discover_predecessor_source(source, path) end)
      |> Enum.sort_by(&row_sort_key/1)

    expected_rows = Enum.map(rows, &Map.drop(&1, ["predecessor_target"]))

    expected_rows
    |> expected_summary()
    |> Map.put("provenance", %{
      "source_sha" => @predecessor_sha,
      "generator" => "git object database; normalized Elixir AST"
    })
    |> put_in(["digests", "predecessor_rows_sha256"], digest(rows))
  end

  @doc "Discover facade calls in one predecessor source string."
  @spec discover_predecessor_source(String.t(), Path.t()) :: [map()]
  def discover_predecessor_source(source, source_path) do
    discover_source(source, source_path, @predecessor_targets, :predecessor)
  end

  @doc "Discover approved direct-owner calls in one current source string."
  @spec discover_current_source(String.t(), Path.t()) :: [map()]
  def discover_current_source(source, source_path) do
    discover_source(source, source_path, @current_targets, :current)
  end

  defp current_inventory(paths) do
    discover_repository(&discover_current_source/2, paths)
    |> expected_summary()
  end

  defp discover_repository(discover, paths) do
    @source_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(@repo_root, glob)) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&MapSet.member?(paths, Path.relative_to(&1, @repo_root)))
    |> Enum.flat_map(fn path ->
      discover.(File.read!(path), Path.relative_to(path, @repo_root))
    end)
    |> Enum.sort_by(&row_sort_key/1)
  end

  defp discover_source(source, source_path, targets, mode) do
    source
    |> Code.string_to_quoted!(file: source_path)
    |> collect_modules(source_path, targets, mode, [])
    |> Enum.sort_by(&row_sort_key/1)
  end

  defp collect_modules(
         {:defmodule, _meta, [module_ast, [do: body]]},
         source_path,
         targets,
         mode,
         acc
       ) do
    module = module_name(module_ast)
    aliases = aliases_in(body)
    {rows, nested_modules} = scan_module(module, source_path, body, aliases, targets, mode)

    Enum.reduce(nested_modules, rows ++ acc, fn nested, nested_acc ->
      collect_modules(nested, source_path, targets, mode, nested_acc)
    end)
  end

  defp collect_modules({:__block__, _meta, forms}, source_path, targets, mode, acc) do
    Enum.reduce(forms, acc, fn form, rows ->
      collect_modules(form, source_path, targets, mode, rows)
    end)
  end

  defp collect_modules(_ast, _source_path, _targets, _mode, acc), do: acc

  defp scan_module(module, source_path, body, aliases, targets, mode) do
    {rows, nested, _clauses} =
      body
      |> block_forms()
      |> Enum.reduce({[], [], %{}}, fn
        {:defmodule, _meta, _args} = nested_module, {rows, nested, clauses} ->
          {rows, [nested_module | nested], clauses}

        {kind, _meta, [head, options]}, {rows, nested, clauses}
        when kind in [:def, :defp] and is_list(options) ->
          case callable(head) do
            {name, arity} ->
              key = {name, arity}
              clause = Map.get(clauses, key, 0) + 1
              caller = "#{name}/#{arity}"

              discovered =
                options
                |> Keyword.get(:do)
                |> calls_in_body(aliases, targets)
                |> Enum.with_index(1)
                |> Enum.map(fn {call, order} ->
                  call_row(
                    call,
                    source_path,
                    module,
                    caller,
                    clause,
                    order,
                    mode
                  )
                end)

              {rows ++ discovered, nested, Map.put(clauses, key, clause)}

            nil ->
              {rows, nested, clauses}
          end

        _form, state ->
          state
      end)

    {rows, Enum.reverse(nested)}
  end

  defp calls_in_body(nil, _aliases, _targets), do: []

  defp calls_in_body(body, aliases, targets) do
    {_body, calls} =
      Macro.prewalk(body, [], fn
        {:|>, _pipe_meta,
         [piped_argument, {{:., _dot_meta, [owner_ast, function]}, _call_meta, arguments}]} =
            node,
        calls
        when is_atom(function) and is_list(arguments) ->
          owner = resolve_module(owner_ast, aliases)
          effective_arguments = [piped_argument | arguments]

          case Map.fetch(targets, {owner, function, length(effective_arguments)}) do
            {:ok, {role, target}} ->
              call = %{
                role: role,
                target: target,
                predecessor_target: "#{owner}.#{function}/#{length(effective_arguments)}",
                arguments: Enum.map(effective_arguments, &normalized_source/1)
              }

              {node, [call | calls]}

            :error ->
              {node, calls}
          end

        {{:., _dot_meta, [owner_ast, function]}, _call_meta, arguments} = node, calls
        when is_atom(function) and is_list(arguments) ->
          owner = resolve_module(owner_ast, aliases)

          case Map.fetch(targets, {owner, function, length(arguments)}) do
            {:ok, {role, target}} ->
              call = %{
                role: role,
                target: target,
                predecessor_target: "#{owner}.#{function}/#{length(arguments)}",
                arguments: Enum.map(arguments, &normalized_source/1)
              }

              {node, [call | calls]}

            :error ->
              {node, calls}
          end

        node, calls ->
          {node, calls}
      end)

    Enum.reverse(calls)
  end

  defp call_row(call, source_path, module, caller, clause, order, mode) do
    row = %{
      "source_path" => source_path,
      "module" => module,
      "caller" => caller,
      "clause" => clause,
      "order" => order,
      "caller_kind" => caller_kind(source_path),
      "role" => call.role,
      "arguments" => call.arguments,
      "target" => call.target
    }

    if mode == :predecessor,
      do: Map.put(row, "predecessor_target", call.predecessor_target),
      else: row
  end

  defp aliases_in(body) do
    body
    |> block_forms()
    |> Enum.reduce(%{}, fn
      {:alias, _meta, args}, aliases -> add_aliases(aliases, args)
      _form, aliases -> aliases
    end)
  end

  defp add_aliases(aliases, [{{:., _meta, [base_ast, :{}]}, _call_meta, members}]) do
    base = module_segments(base_ast)

    Enum.reduce(members, aliases, fn member, acc ->
      full = base ++ module_segments(member)

      if full != [] and Enum.all?(full, &is_atom/1),
        do: Map.put(acc, List.last(full), Enum.join(full, ".")),
        else: acc
    end)
  end

  defp add_aliases(aliases, [module_ast | options]) do
    full = module_segments(module_ast)

    options =
      case options do
        [nested] when is_list(nested) -> nested
        flat -> flat
      end

    if full != [] and Enum.all?(full, &is_atom/1) do
      short =
        case Keyword.get(options, :as) do
          nil -> List.last(full)
          as_ast -> as_ast |> module_segments() |> List.last()
        end

      Map.put(aliases, short, Enum.join(full, "."))
    else
      aliases
    end
  end

  defp add_aliases(aliases, _args), do: aliases

  defp resolve_module({:__aliases__, _meta, segments}, aliases) do
    case segments do
      [first | rest] ->
        case Map.fetch(aliases, first) do
          {:ok, expanded} -> Enum.join([expanded | Enum.map(rest, &Atom.to_string/1)], ".")
          :error -> Enum.map_join(segments, ".", &Atom.to_string/1)
        end

      [] ->
        ""
    end
  end

  defp resolve_module(_ast, _aliases), do: ""

  defp module_name(ast), do: ast |> module_segments() |> Enum.join(".")

  defp module_segments({:__aliases__, _meta, segments}) do
    if Enum.all?(segments, &is_atom/1), do: segments, else: []
  end

  defp module_segments(atom) when is_atom(atom), do: [atom]
  defp module_segments(_ast), do: []

  defp callable({:when, _meta, [head | _guards]}), do: callable(head)

  defp callable({name, _meta, arguments}) when is_atom(name) and is_list(arguments),
    do: {name, length(arguments)}

  defp callable(_head), do: nil

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(nil), do: []
  defp block_forms(form), do: [form]

  defp normalized_source(ast) do
    ast
    |> Macro.prewalk(fn
      {name, metadata, arguments} when is_list(metadata) ->
        {name, Keyword.drop(metadata, [:line, :column, :end_of_expression]), arguments}

      node ->
        node
    end)
    |> Macro.to_string()
  end

  defp caller_kind(source_path), do: Map.get(@non_action_paths, source_path, "action")

  defp expected_summary(rows) do
    files = file_summaries(rows)

    %{
      "schema_version" => @schema_version,
      "normalization" => @normalization,
      "counts" => counts(rows),
      "non_action_families" => non_action_families(rows),
      "files" => files,
      "digests" => %{
        "expected_rows_sha256" => digest(rows),
        "files_sha256" => digest(files)
      }
    }
  end

  defp file_summaries(rows) do
    rows
    |> Enum.group_by(& &1["source_path"])
    |> Enum.map(fn {source_path, file_rows} ->
      %{
        "source_path" => source_path,
        "caller_kind" => hd(file_rows)["caller_kind"],
        "calls" => length(file_rows),
        "roles" => Enum.frequencies_by(file_rows, & &1["role"]),
        "expected_rows_sha256" => digest(file_rows)
      }
    end)
    |> Enum.sort_by(& &1["source_path"])
  end

  defp counts(rows) do
    role_counts = Enum.frequencies_by(rows, & &1["role"])

    vocabulary =
      length(rows) - Map.get(role_counts, "authorize", 0) -
        Map.get(role_counts, "response_status", 0) - Map.get(role_counts, "allowed", 0)

    %{
      "files" => rows |> Enum.map(& &1["source_path"]) |> Enum.uniq() |> length(),
      "permission_call_files" =>
        rows
        |> Enum.reject(&(&1["role"] not in ["authorize", "response_status", "allowed"]))
        |> Enum.map(& &1["source_path"])
        |> Enum.uniq()
        |> length(),
      "calls" => length(rows),
      "authorize" => Map.get(role_counts, "authorize", 0),
      "response_status" => Map.get(role_counts, "response_status", 0),
      "allowed" => Map.get(role_counts, "allowed", 0),
      "vocabulary" => vocabulary
    }
  end

  defp non_action_families(rows) do
    rows
    |> Enum.reject(&(&1["caller_kind"] == "action"))
    |> Enum.group_by(& &1["caller_kind"])
    |> Map.new(fn {family, family_rows} ->
      {family,
       %{
         "calls" => length(family_rows),
         "files" => family_rows |> Enum.map(& &1["source_path"]) |> Enum.uniq() |> Enum.sort()
       }}
    end)
  end

  defp counts_from_files(files) do
    roles =
      Enum.reduce(files, %{}, fn file, acc ->
        Map.merge(acc, file["roles"], fn _role, left, right -> left + right end)
      end)

    permission_roles = ["authorize", "response_status", "allowed"]

    %{
      "files" => length(files),
      "permission_call_files" =>
        Enum.count(files, fn file ->
          Enum.any?(permission_roles, &Map.has_key?(file["roles"], &1))
        end),
      "calls" => Enum.sum(Enum.map(files, & &1["calls"])),
      "authorize" => Map.get(roles, "authorize", 0),
      "response_status" => Map.get(roles, "response_status", 0),
      "allowed" => Map.get(roles, "allowed", 0),
      "vocabulary" =>
        roles
        |> Enum.reject(fn {role, _count} -> role in permission_roles end)
        |> Enum.sum_by(fn {_role, count} -> count end)
    }
  end

  defp non_action_families_from_files(files) do
    files
    |> Enum.reject(&(&1["caller_kind"] == "action"))
    |> Enum.group_by(& &1["caller_kind"])
    |> Map.new(fn {family, family_files} ->
      {family,
       %{
         "calls" => Enum.sum(Enum.map(family_files, & &1["calls"])),
         "files" => Enum.map(family_files, & &1["source_path"])
       }}
    end)
  end

  defp row_sort_key(row) do
    {
      row["source_path"],
      row["module"],
      row["caller"],
      row["clause"],
      row["order"]
    }
  end

  defp digest(value) do
    value
    |> CanonicalJSON.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
