defmodule AllbertAssist.DevGates.V14M4SemanticsInventory do
  @moduledoc """
  Source-owned v1.4 M4 decision ledger for divergent local primitives.

  The inventory binds every production `truthy?/1` and `json_safe/1`
  definition to its local callers without relying on source line numbers. The
  fixture supplies the reviewed semantic profile, purpose, boundary class, and
  consolidation disposition. New definitions, callers, or semantic changes
  therefore fail closed until their decision is recorded.
  """

  @schema_version 1
  @normalization "v14_m4_semantics_inventory_v1"
  @targets [{:truthy?, 1}, {:json_safe, 1}]
  @dispositions ["retain_local", "named_equivalence"]
  @repo_root Path.expand("../../../../..", __DIR__)
  @source_globs ["apps/*/lib/**/*.ex", "plugins/*/lib/**/*.ex"]

  @doc "Return the repository-owned v1.4 M4 semantics fixture path."
  @spec fixture_path() :: Path.t()
  def fixture_path do
    Path.expand("../../../test/fixtures/v1.4/m4_semantics_inventory.json", __DIR__)
  end

  @doc "Discover the current source inventory and merge its reviewed decisions."
  @spec snapshot() :: map()
  def snapshot do
    fixture = load_fixture!()
    source = source_inventory()
    decisions = decisions_by_id!(fixture["definitions"])

    definitions =
      Enum.map(source["definitions"], fn definition ->
        decision =
          Map.get(decisions, definition["id"]) ||
            raise "unaccounted v1.4 M4 semantics definition: #{definition["id"]}"

        merge_definition_decision!(definition, decision)
      end)

    source
    |> Map.put("definitions", definitions)
    |> Map.put("counts", counts(definitions))
  end

  @doc "Load and validate the reviewed decision fixture."
  @spec load_fixture!() :: map()
  def load_fixture! do
    fixture = fixture_path() |> File.read!() |> Jason.decode!()

    unless fixture["schema_version"] == @schema_version and
             fixture["normalization"] == @normalization and
             is_list(fixture["definitions"]) do
      raise "invalid v1.4 M4 semantics inventory fixture"
    end

    definitions = fixture["definitions"]
    _unique = decisions_by_id!(definitions)
    Enum.each(definitions, &validate_decision!/1)

    if fixture["counts"] != counts(definitions) do
      raise "invalid v1.4 M4 semantics inventory fixture counts"
    end

    fixture
  end

  @doc "Fail when production definitions, use-sites, or reviewed decisions drift."
  @spec check!() :: :ok
  def check! do
    frozen = load_fixture!()
    live = snapshot()

    if frozen == live do
      :ok
    else
      raise "v1.4 M4 semantics inventory drift: " <>
              "frozen=#{digest(frozen["definitions"])} " <>
              "live=#{digest(live["definitions"])}"
    end
  end

  @doc "Discover all production definitions and local call/capture sites."
  @spec source_inventory() :: map()
  def source_inventory do
    definitions =
      @source_globs
      |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(@repo_root, glob)) end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> discover_source(Path.relative_to(path, @repo_root))
      end)
      |> Enum.sort_by(& &1["id"])

    %{
      "schema_version" => @schema_version,
      "normalization" => @normalization,
      "definitions" => definitions,
      "counts" => counts(definitions)
    }
  end

  @doc "Discover target definitions in one Elixir source string."
  @spec discover_source(String.t(), Path.t()) :: [map()]
  def discover_source(source, source_path) do
    source
    |> Code.string_to_quoted!(file: source_path)
    |> collect_modules(source_path, [])
    |> Enum.map(&finalize_definition/1)
    |> Enum.sort_by(& &1["id"])
  end

  defp collect_modules({:defmodule, _meta, [module_ast, [do: body]]}, source_path, acc) do
    module = module_name(module_ast)
    {module_definitions, nested_modules} = scan_module(module, source_path, body)

    Enum.reduce(nested_modules, module_definitions ++ acc, fn nested, nested_acc ->
      collect_modules(nested, source_path, nested_acc)
    end)
  end

  defp collect_modules({:__block__, _meta, forms}, source_path, acc) do
    Enum.reduce(forms, acc, &collect_modules(&1, source_path, &2))
  end

  defp collect_modules(_ast, _source_path, acc), do: acc

  defp scan_module(module, source_path, body) do
    body
    |> block_forms()
    |> Enum.reduce({%{}, []}, fn
      {:defmodule, _meta, _args} = nested, {definitions, nested_modules} ->
        {definitions, [nested | nested_modules]}

      {kind, _meta, [head, body_options]} = definition, {definitions, nested_modules}
      when kind in [:def, :defp] and is_list(body_options) ->
        case callable(head) do
          {caller_name, caller_arity} ->
            caller = "#{caller_name}/#{caller_arity}"
            uses = discover_uses(Keyword.get(body_options, :do), caller)

            definitions =
              Enum.reduce(uses, definitions, fn {{name, arity}, use}, definitions ->
                update_definition(definitions, module, source_path, name, arity, nil, use)
              end)

            definitions =
              if {caller_name, caller_arity} in @targets do
                update_definition(
                  definitions,
                  module,
                  source_path,
                  caller_name,
                  caller_arity,
                  definition,
                  nil
                )
              else
                definitions
              end

            {definitions, nested_modules}

          nil ->
            {definitions, nested_modules}
        end

      _other, state ->
        state
    end)
    |> then(fn {definitions, nested} -> {Map.values(definitions), Enum.reverse(nested)} end)
  end

  defp discover_uses(nil, _caller), do: %{}

  defp discover_uses(body, caller) do
    {_body, uses} =
      Macro.prewalk(body, %{}, fn
        {:&, _meta, [{:/, _slash_meta, [{name, _name_meta, context}, arity]}]} = node, uses
        when is_atom(context) and {name, arity} in @targets ->
          {node, record_use(uses, {name, arity}, caller, :capture, node)}

        {name, _meta, args} = node, uses
        when is_list(args) and {name, length(args)} in @targets ->
          {node, record_use(uses, {name, length(args)}, caller, :call, node)}

        node, uses ->
          {node, uses}
      end)

    uses
  end

  defp record_use(uses, target, caller, form, node) do
    update_in(uses, [Access.key(target, %{}), Access.key(caller, empty_use(caller))], fn use ->
      use
      |> Map.update!(form, &(&1 + 1))
      |> Map.update!(:nodes, &[normalized_source(node) | &1])
    end)
  end

  defp empty_use(caller), do: %{caller: caller, call: 0, capture: 0, nodes: []}

  defp update_definition(definitions, module, source_path, name, arity, clause, use) do
    key = {module, name, arity}

    row =
      Map.get(definitions, key, %{
        module: module,
        source_path: source_path,
        function: Atom.to_string(name),
        arity: arity,
        clauses: [],
        uses: %{}
      })

    row = if clause, do: Map.update!(row, :clauses, &[clause | &1]), else: row

    row =
      if use do
        Map.update!(row, :uses, fn existing ->
          Map.merge(existing, use, fn _caller, left, right ->
            %{
              caller: left.caller,
              call: left.call + right.call,
              capture: left.capture + right.capture,
              nodes: left.nodes ++ right.nodes
            }
          end)
        end)
      else
        row
      end

    Map.put(definitions, key, row)
  end

  defp finalize_definition(%{clauses: []} = definition) do
    raise "local semantics use has no matching definition: " <>
            "#{definition.module}.#{definition.function}/#{definition.arity}"
  end

  defp finalize_definition(definition) do
    use_sites =
      definition.uses
      |> Map.values()
      |> Enum.map(fn use ->
        %{
          "caller" => use.caller,
          "call_count" => use.call,
          "capture_count" => use.capture,
          "use_sha256" => use.nodes |> Enum.reverse() |> digest()
        }
      end)
      |> Enum.sort_by(& &1["caller"])

    id = "#{definition.module}.#{definition.function}/#{definition.arity}"

    %{
      "id" => id,
      "module" => definition.module,
      "source_path" => definition.source_path,
      "function" => definition.function,
      "arity" => definition.arity,
      "definition_sha256" =>
        definition.clauses |> Enum.reverse() |> Enum.map(&normalized_source/1) |> digest(),
      "use_sites" => use_sites
    }
  end

  defp merge_definition_decision!(source, decision) do
    source_uses = Map.new(source["use_sites"], &{&1["caller"], &1})
    decision_uses = Map.new(decision["use_sites"], &{&1["caller"], &1})

    use_sites =
      Enum.map(source["use_sites"], fn use_site ->
        reviewed =
          Map.get(decision_uses, use_site["caller"]) ||
            raise "unaccounted v1.4 M4 semantics use-site: " <>
                    "#{source["id"]} from #{use_site["caller"]}"

        Map.merge(use_site, Map.take(reviewed, ["purpose", "trust_or_wire"]))
      end)

    removed_callers = Map.keys(decision_uses) -- Map.keys(source_uses)

    if removed_callers != [] do
      raise "removed v1.4 M4 semantics use-site(s) for #{source["id"]}: " <>
              Enum.join(Enum.sort(removed_callers), ", ")
    end

    source
    |> Map.merge(Map.take(decision, ["profile", "purpose", "trust_or_wire", "disposition"]))
    |> Map.put("use_sites", use_sites)
  end

  defp validate_decision!(definition) do
    required = ["profile", "purpose", "trust_or_wire", "disposition"]

    unless Enum.all?(required, &(is_binary(definition[&1]) and definition[&1] != "")) and
             definition["disposition"] in @dispositions and
             is_list(definition["use_sites"]) and definition["use_sites"] != [] and
             Enum.all?(definition["use_sites"], &valid_use_decision?/1) do
      raise "invalid v1.4 M4 semantics decision: #{inspect(definition["id"])}"
    end
  end

  defp valid_use_decision?(use_site) do
    is_binary(use_site["caller"]) and use_site["caller"] != "" and
      is_binary(use_site["purpose"]) and use_site["purpose"] != "" and
      is_binary(use_site["trust_or_wire"]) and use_site["trust_or_wire"] != ""
  end

  defp decisions_by_id!(definitions) do
    decisions = Map.new(definitions, &{&1["id"], &1})

    if map_size(decisions) == length(definitions) do
      decisions
    else
      raise "duplicate definition id in v1.4 M4 semantics inventory fixture"
    end
  end

  defp counts(definitions) do
    %{
      "definitions" => length(definitions),
      "truthy" => Enum.count(definitions, &(&1["function"] == "truthy?")),
      "json_safe" => Enum.count(definitions, &(&1["function"] == "json_safe")),
      "use_sites" =>
        Enum.reduce(definitions, 0, fn definition, count ->
          count + length(definition["use_sites"])
        end)
    }
  end

  defp callable({:when, _meta, [head | _guards]}), do: callable(head)
  defp callable({name, _meta, args}) when is_atom(name), do: {name, length(args || [])}
  defp callable(_head), do: nil

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(form), do: [form]

  defp module_name({:__aliases__, _meta, parts}), do: Enum.join(parts, ".")
  defp module_name(module), do: Macro.to_string(module)

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalized_source(ast) do
    Macro.prewalk(ast, fn
      {name, metadata, arguments} when is_atom(name) and is_list(metadata) ->
        {name, [], arguments}

      node ->
        node
    end)
  end
end
