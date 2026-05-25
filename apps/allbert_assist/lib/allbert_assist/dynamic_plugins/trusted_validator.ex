defmodule AllbertAssist.DynamicPlugins.TrustedValidator do
  @moduledoc """
  Trusted-phase validator for v0.37 dynamic action source.

  The validator parses reviewed source into AST without executing it, then
  applies a deliberately small allowlist before the loader may compile the
  source into the core node. v0.37's live path accepts read-only generated
  actions only; apps, panels, children, settings fragments, and route-like
  surfaces remain rejected until they have their own trusted validators.
  """

  alias AllbertAssist.Action
  alias AllbertAssist.DynamicPlugins.Draft

  @generated_prefix "AllbertAssist.DynamicPlugins.Generated"
  @allowed_targets ["action"]
  @allowed_action_permissions ["read_only"]

  @allowed_remote_calls %{
    "Atom" => [:to_string],
    "Date" => [:add, :compare, :diff, :to_iso8601],
    "DateTime" => [:compare, :diff, :to_date, :to_iso8601, :to_time, :truncate],
    "Enum" => [
      :all?,
      :any?,
      :at,
      :chunk_every,
      :count,
      :drop,
      :empty?,
      :filter,
      :find,
      :flat_map,
      :join,
      :map,
      :max,
      :min,
      :reject,
      :reverse,
      :sort,
      :sum,
      :take,
      :uniq,
      :with_index
    ],
    "Float" => [:ceil, :floor, :parse, :round, :to_string],
    "Integer" => [:digits, :floor_div, :mod, :parse, :to_string],
    "Kernel" => [:inspect, :to_string],
    "Keyword" => [:delete, :drop, :get, :has_key?, :keys, :merge, :new, :put, :take, :values],
    "List" => [
      :delete,
      :delete_at,
      :first,
      :flatten,
      :insert_at,
      :last,
      :replace_at,
      :to_tuple,
      :wrap,
      :zip
    ],
    "Map" => [:delete, :drop, :get, :has_key?, :keys, :merge, :new, :put, :take, :values],
    "String" => [
      :capitalize,
      :contains?,
      :downcase,
      :duplicate,
      :ends_with?,
      :first,
      :graphemes,
      :join,
      :last,
      :length,
      :replace,
      :slice,
      :split,
      :starts_with?,
      :trim,
      :trim_leading,
      :trim_trailing,
      :upcase
    ],
    "Time" => [:add, :compare, :diff, :to_iso8601, :truncate],
    "Tuple" => [:append, :delete_at, :duplicate, :insert_at, :to_list]
  }

  @protected_remote_prefixes [
    "AllbertAssist.Actions",
    "AllbertAssist.Confirmations",
    "AllbertAssist.DynamicPlugins.Loader",
    "AllbertAssist.Execution",
    "AllbertAssist.Repo",
    "AllbertAssist.Resources",
    "AllbertAssist.Sandbox",
    "AllbertAssist.Settings",
    "AllbertAssist.Skills",
    "AllbertAssist.Trace",
    "Application",
    "Code",
    "File",
    "Mix",
    "Node",
    "Port",
    "Process",
    "System",
    ":code",
    ":erlang",
    ":os"
  ]

  @forbidden_local_calls [
    :apply,
    :defdelegate,
    :defexception,
    :defguard,
    :defguardp,
    :defimpl,
    :defmacro,
    :defmacrop,
    :defoverridable,
    :defprotocol,
    :import,
    :quote,
    :raise,
    :receive,
    :require,
    :send,
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :throw,
    :try,
    :unquote
  ]

  @allowed_local_calls [
    :{},
    :%{},
    :!,
    :!=,
    :!==,
    :&&,
    :*,
    :+,
    :++,
    :-,
    :--,
    :..,
    :/,
    :<,
    :<=,
    :<>,
    :=,
    :==,
    :===,
    :=~,
    :>,
    :>=,
    :case,
    :cond,
    :if,
    :in,
    :and,
    :is_atom,
    :is_binary,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_nil,
    :is_number,
    :is_tuple,
    :not,
    :or,
    :to_string
  ]

  @type validation :: %{
          modules: [String.t()],
          actions: [map()],
          source_files: [map()],
          diagnostics: [map()]
        }

  @doc "Validate one gate-passed draft manifest and source tree."
  @spec validate(Draft.t(), map(), keyword()) :: {:ok, validation()} | {:error, term()}
  def validate(draft, manifest, opts \\ [])

  def validate(%Draft{} = draft, manifest, opts) when is_map(manifest) do
    root = Keyword.get(opts, :root, draft.root)

    with :ok <- validate_targets(draft, manifest),
         {:ok, files} <- manifest_source_files(manifest),
         {:ok, declared_modules} <- declared_modules(manifest),
         {:ok, action_specs} <- action_specs(manifest),
         :ok <- validate_declared_modules(draft.slug, declared_modules),
         :ok <- validate_action_specs(action_specs, declared_modules),
         {:ok, source_files} <- parse_sources(root, draft.slug, files),
         :ok <- validate_manifest_modules(source_files, declared_modules) do
      {:ok,
       %{
         modules: discovered_modules(source_files),
         actions: action_specs,
         source_files: source_files,
         diagnostics: []
       }}
    end
  end

  def validate(_draft, _manifest, _opts), do: {:error, :invalid_dynamic_validation_input}

  defp validate_targets(%Draft{} = draft, manifest) do
    manifest_targets = string_list(field(manifest, "target_shapes", draft.target_shapes))
    targets = Enum.uniq(draft.target_shapes ++ manifest_targets)

    cond do
      targets == [] ->
        {:error, {:missing_dynamic_target_shapes, @allowed_targets}}

      Enum.all?(targets, &(&1 in @allowed_targets)) ->
        :ok

      true ->
        {:error, {:unsupported_dynamic_target_shapes, targets -- @allowed_targets}}
    end
  end

  defp manifest_source_files(manifest) do
    files =
      manifest
      |> field("files", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn entry ->
        %{
          source_path: field(entry, "source_path"),
          compiled_path: field(entry, "compiled_path")
        }
      end)

    cond do
      files == [] ->
        {:error, :missing_dynamic_source_files}

      Enum.any?(files, &(blank?(&1.source_path) or blank?(&1.compiled_path))) ->
        {:error, {:invalid_dynamic_source_files, files}}

      true ->
        {:ok, files}
    end
  end

  defp declared_modules(manifest) do
    modules =
      manifest
      |> field("modules", [])
      |> string_list()
      |> Enum.reject(&blank?/1)

    if modules == [], do: {:error, :missing_dynamic_modules}, else: {:ok, modules}
  end

  defp action_specs(manifest) do
    actions =
      manifest
      |> field("actions", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&normalize_action_spec/1)

    cond do
      actions == [] ->
        {:error, :missing_dynamic_actions}

      Enum.any?(actions, &(blank?(&1.name) or blank?(&1.module))) ->
        {:error, {:invalid_dynamic_actions, actions}}

      true ->
        {:ok, actions}
    end
  end

  defp normalize_action_spec(spec) do
    %{
      name: field(spec, "name"),
      module: field(spec, "module"),
      permission: field(spec, "permission", "read_only"),
      exposure: field(spec, "exposure", "internal")
    }
  end

  defp validate_declared_modules(slug, modules) do
    prefix = generated_slug_prefix(slug)

    case Enum.reject(modules, &generated_module?(&1, prefix)) do
      [] -> :ok
      invalid -> {:error, {:dynamic_module_outside_namespace, invalid}}
    end
  end

  defp validate_action_specs(actions, declared_modules) do
    cond do
      Enum.any?(actions, &(&1.permission not in @allowed_action_permissions)) ->
        {:error, {:unsupported_dynamic_action_permissions, Enum.map(actions, & &1.permission)}}

      Enum.any?(actions, &(&1.exposure not in ["agent", "internal"])) ->
        {:error, {:unsupported_dynamic_action_exposure, Enum.map(actions, & &1.exposure)}}

      Enum.any?(actions, &(&1.module not in declared_modules)) ->
        {:error, {:dynamic_action_module_not_declared, Enum.map(actions, & &1.module)}}

      true ->
        :ok
    end
  end

  defp parse_sources(root, slug, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      path = Path.join(root, file.source_path)

      with {:ok, source} <- File.read(path),
           {:ok, ast} <- Code.string_to_quoted(source, file: path),
           {:ok, source_file} <- validate_source_ast(ast, slug, file, source, path) do
        {:cont, {:ok, [source_file | acc]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:trusted_validation_failed, file.source_path, reason}}}
      end
    end)
    |> case do
      {:ok, source_files} -> {:ok, Enum.reverse(source_files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_source_ast(ast, slug, file, source, path) do
    forms = top_level_forms(ast)
    prefix = generated_slug_prefix(slug)

    modules =
      Enum.flat_map(forms, fn
        {:defmodule, _meta, [module_ast, [do: body]]} ->
          module = module_name(module_ast)

          case validate_module_body(module, prefix, body) do
            :ok -> [module]
            {:error, reason} -> throw({:error, reason})
          end

        other ->
          throw({:error, {:unsupported_top_level_form, form_name(other)}})
      end)

    {:ok, %{path: path, source_path: file.source_path, source: source, modules: modules}}
  catch
    {:error, reason} -> {:error, reason}
  end

  defp validate_module_body(module, prefix, body) do
    cond do
      not is_binary(module) ->
        {:error, :invalid_dynamic_module_name}

      not generated_module?(module, prefix) ->
        {:error, {:dynamic_module_outside_namespace, module}}

      true ->
        forms = top_level_forms(body)
        local_defs = local_defs(forms)
        validate_module_forms(forms, module, local_defs)
    end
  end

  defp validate_module_forms(forms, module, local_defs) do
    Enum.reduce_while(forms, :ok, fn form, :ok ->
      case validate_module_form(form, module, local_defs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_module_form({:@, _meta, [{attr, _attr_meta, args}]}, _module, _local_defs)
       when attr in [:impl, :doc, :moduledoc] do
    if literal_list?(args), do: :ok, else: {:error, {:non_literal_module_attribute, attr}}
  end

  defp validate_module_form({:@, _meta, [{attr, _attr_meta, _args}]}, _module, _local_defs)
       when attr in [:on_load, :compile] do
    {:error, {:forbidden_module_attribute, attr}}
  end

  defp validate_module_form({:use, _meta, [target | args]}, _module, _local_defs) do
    with "AllbertAssist.Action" <- module_name(target),
         true <- literal_list?(args),
         :ok <- validate_action_use_options(args) do
      :ok
    else
      false -> {:error, :non_literal_action_use_options}
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:unsupported_use_target, module_name(target)}}
    end
  end

  defp validate_module_form({:alias, _meta, [target]}, _module, _local_defs) do
    if generated_or_action_module?(module_name(target)) do
      :ok
    else
      {:error, {:unsupported_alias_target, module_name(target)}}
    end
  end

  defp validate_module_form(
         {kind, _meta, [{name, _name_meta, args}, [do: body]]},
         _module,
         local_defs
       )
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    validate_expression(body, local_defs)
  end

  defp validate_module_form({kind, _meta, _args}, _module, _local_defs)
       when kind in @forbidden_local_calls do
    {:error, {:forbidden_module_form, kind}}
  end

  defp validate_module_form(other, _module, _local_defs) do
    {:error, {:unsupported_module_form, form_name(other)}}
  end

  defp validate_expression(value, _local_defs) when is_atom(value) or is_binary(value), do: :ok
  defp validate_expression(value, _local_defs) when is_number(value) or is_boolean(value), do: :ok

  defp validate_expression(values, local_defs) when is_list(values) do
    validate_each(values, &validate_expression(&1, local_defs))
  end

  defp validate_expression({:%{}, _meta, pairs}, local_defs) do
    validate_each(pairs, fn {key, value} ->
      with :ok <- validate_expression(key, local_defs) do
        validate_expression(value, local_defs)
      end
    end)
  end

  defp validate_expression({:{}, _meta, values}, local_defs) do
    validate_each(values, &validate_expression(&1, local_defs))
  end

  defp validate_expression({:<<>>, _meta, parts}, local_defs) do
    validate_each(parts, &validate_expression(&1, local_defs))
  end

  defp validate_expression({:"::", _meta, [value, _type]}, local_defs) do
    validate_expression(value, local_defs)
  end

  defp validate_expression({left, right}, local_defs) do
    with :ok <- validate_expression(left, local_defs) do
      validate_expression(right, local_defs)
    end
  end

  defp validate_expression({:=, _meta, [left, right]}, local_defs) do
    with :ok <- validate_pattern(left) do
      validate_expression(right, local_defs)
    end
  end

  defp validate_expression({:case, _meta, [value, [do: clauses]]}, local_defs) do
    with :ok <- validate_expression(value, local_defs) do
      validate_each(clauses, &validate_case_clause(&1, local_defs))
    end
  end

  defp validate_expression({:cond, _meta, [[do: clauses]]}, local_defs) do
    validate_each(clauses, &validate_condition_clause(&1, local_defs))
  end

  defp validate_expression({:if, _meta, [condition, clauses]}, local_defs) do
    with :ok <- validate_expression(condition, local_defs) do
      validate_each(Keyword.values(clauses), &validate_expression(&1, local_defs))
    end
  end

  defp validate_expression({:with, _meta, clauses}, local_defs) do
    {body, clauses} = Keyword.pop(clauses, :do)
    {_else_body, clauses} = Keyword.pop(clauses, :else)

    with :ok <- validate_each(clauses, &validate_with_clause(&1, local_defs)) do
      validate_expression(body, local_defs)
    end
  end

  defp validate_expression({:for, _meta, clauses}, local_defs) do
    {body, clauses} = Keyword.pop(clauses, :do)

    with :ok <- validate_each(clauses, &validate_for_clause(&1, local_defs)) do
      validate_expression(body, local_defs)
    end
  end

  defp validate_expression({:fn, _meta, clauses}, local_defs) do
    validate_each(clauses, &validate_fn_clause(&1, local_defs))
  end

  defp validate_expression({:&, _meta, [capture]}, local_defs) do
    validate_capture(capture, local_defs)
  end

  defp validate_expression({:__block__, _meta, expressions}, local_defs) do
    validate_each(expressions, &validate_expression(&1, local_defs))
  end

  defp validate_expression({{:., _meta, [module_ast, function]}, _call_meta, args}, local_defs)
       when is_atom(function) and is_list(args) do
    module = module_name(module_ast)

    cond do
      protected_remote?(module) ->
        {:error, {:protected_remote_call, module, function}}

      allowed_remote_call?(module, function) or generated_module_name?(module) ->
        validate_each(args, &validate_expression(&1, local_defs))

      true ->
        {:error, {:unsupported_remote_call, module, function}}
    end
  end

  defp validate_expression({name, _meta, context}, _local_defs)
       when is_atom(name) and is_atom(context) do
    :ok
  end

  defp validate_expression({name, _meta, args}, local_defs)
       when is_atom(name) and is_list(args) do
    cond do
      name in @forbidden_local_calls ->
        {:error, {:forbidden_local_call, name}}

      name in @allowed_local_calls or {name, length(args)} in local_defs ->
        validate_each(args, &validate_expression(&1, local_defs))

      true ->
        {:error, {:unsupported_local_call, name}}
    end
  end

  defp validate_expression(other, _local_defs),
    do: {:error, {:unsupported_expression, form_name(other)}}

  defp validate_pattern({name, _meta, context}) when is_atom(name) and is_atom(context), do: :ok

  defp validate_pattern(values) when is_list(values),
    do: validate_each(values, &validate_pattern/1)

  defp validate_pattern({:%{}, _meta, pairs}) do
    validate_each(pairs, fn {key, value} ->
      with :ok <- validate_expression(key, []) do
        validate_pattern(value)
      end
    end)
  end

  defp validate_pattern({left, right}) do
    with :ok <- validate_pattern(left) do
      validate_pattern(right)
    end
  end

  defp validate_pattern({:{}, _meta, values}), do: validate_each(values, &validate_pattern/1)
  defp validate_pattern(value) when is_atom(value) or is_binary(value), do: :ok
  defp validate_pattern(value) when is_number(value) or is_boolean(value), do: :ok
  defp validate_pattern(other), do: {:error, {:unsupported_pattern, form_name(other)}}

  defp validate_case_clause({:->, _meta, [patterns, body]}, local_defs) do
    with :ok <- validate_each(List.wrap(patterns), &validate_pattern/1) do
      validate_expression(body, local_defs)
    end
  end

  defp validate_condition_clause({:->, _meta, [[condition], body]}, local_defs) do
    with :ok <- validate_expression(condition, local_defs) do
      validate_expression(body, local_defs)
    end
  end

  defp validate_condition_clause(other, _local_defs),
    do: {:error, {:unsupported_condition_clause, form_name(other)}}

  defp validate_fn_clause({:->, _meta, [patterns, body]}, local_defs) do
    with :ok <- validate_each(List.wrap(patterns), &validate_pattern/1) do
      validate_expression(body, local_defs)
    end
  end

  defp validate_fn_clause(other, _local_defs),
    do: {:error, {:unsupported_fn_clause, form_name(other)}}

  defp validate_with_clause({:<-, _meta, [pattern, expression]}, local_defs) do
    with :ok <- validate_pattern(pattern) do
      validate_expression(expression, local_defs)
    end
  end

  defp validate_with_clause({:=, _meta, [pattern, expression]}, local_defs) do
    with :ok <- validate_pattern(pattern) do
      validate_expression(expression, local_defs)
    end
  end

  defp validate_with_clause(expression, local_defs),
    do: validate_expression(expression, local_defs)

  defp validate_for_clause({:<-, _meta, [pattern, expression]}, local_defs) do
    with :ok <- validate_pattern(pattern) do
      validate_expression(expression, local_defs)
    end
  end

  defp validate_for_clause({:<<>>, _meta, _parts} = expression, local_defs) do
    validate_expression(expression, local_defs)
  end

  defp validate_for_clause(expression, local_defs),
    do: validate_expression(expression, local_defs)

  defp validate_capture({:&, _meta, [index]}, _local_defs) when is_integer(index), do: :ok

  defp validate_capture(
         {:/, _meta, [{{:., _dot_meta, [module_ast, function]}, _call_meta, []}, arity]},
         _local_defs
       )
       when is_atom(function) and is_integer(arity) and arity >= 0 do
    module = module_name(module_ast)

    cond do
      protected_remote?(module) ->
        {:error, {:protected_remote_call, module, function}}

      allowed_remote_call?(module, function) or generated_module_name?(module) ->
        :ok

      true ->
        {:error, {:unsupported_remote_call, module, function}}
    end
  end

  defp validate_capture(expression, local_defs), do: validate_expression(expression, local_defs)

  defp validate_action_use_options(args) do
    opts =
      args
      |> List.flatten()
      |> Enum.filter(&match?({key, _value} when is_atom(key), &1))
      |> Map.new()

    capability_opts = Map.take(opts, Action.capability_keys())

    cond do
      Map.get(capability_opts, :permission) != :read_only ->
        {:error, {:dynamic_action_permission_ceiling, Map.get(capability_opts, :permission)}}

      Map.get(capability_opts, :confirmation) != :not_required ->
        {:error, {:dynamic_action_confirmation_denied, Map.get(capability_opts, :confirmation)}}

      Map.get(capability_opts, :resumable?, false) != false ->
        {:error, :dynamic_action_resumable_denied}

      Map.get(capability_opts, :skill_backed?) != false ->
        {:error, :dynamic_action_skill_backed_denied}

      true ->
        case Action.validate_capability(capability_opts) do
          {:ok, _attrs} -> :ok
          {:error, reason} -> {:error, {:invalid_dynamic_action_capability, reason}}
        end
    end
  end

  defp validate_manifest_modules(source_files, declared_modules) do
    discovered = discovered_modules(source_files)

    if Enum.sort(discovered) == Enum.sort(declared_modules) do
      :ok
    else
      {:error,
       {:dynamic_manifest_module_mismatch, %{declared: declared_modules, discovered: discovered}}}
    end
  end

  defp discovered_modules(source_files) do
    source_files
    |> Enum.flat_map(& &1.modules)
    |> Enum.uniq()
  end

  defp local_defs(forms) do
    forms
    |> Enum.flat_map(fn
      {kind, _meta, [{name, _name_meta, args}, [do: _body]]}
      when kind in [:def, :defp] and is_atom(name) and is_list(args) ->
        [{name, length(args)}]

      _other ->
        []
    end)
  end

  defp top_level_forms({:__block__, _meta, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp generated_slug_prefix(slug), do: "#{@generated_prefix}.#{Macro.camelize(slug)}"

  defp generated_module?(module, prefix) when is_binary(module) do
    String.starts_with?(module, prefix <> ".")
  end

  defp generated_module?(_module, _prefix), do: false

  defp generated_module_name?(module) when is_binary(module),
    do: String.starts_with?(module, @generated_prefix <> ".")

  defp generated_module_name?(_module), do: false

  defp generated_or_action_module?("AllbertAssist.Action"), do: true
  defp generated_or_action_module?(module), do: generated_module_name?(module)

  defp protected_remote?(module) when is_binary(module) do
    Enum.any?(@protected_remote_prefixes, fn prefix ->
      module == prefix or String.starts_with?(module, prefix <> ".")
    end)
  end

  defp protected_remote?(_module), do: true

  defp allowed_remote_call?(module, function) do
    function in Map.get(@allowed_remote_calls, module, [])
  end

  defp module_name({:__aliases__, _meta, parts}) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name({:__MODULE__, _meta, _context}), do: "__MODULE__"
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_module), do: nil

  defp literal_list?(values) when is_list(values), do: Enum.all?(values, &literal?/1)
  defp literal_list?(_values), do: false

  defp literal?({key, value}) when is_atom(key), do: literal?(value)
  defp literal?({:{}, _meta, values}), do: literal_list?(values)

  defp literal?({:%{}, _meta, pairs}),
    do: Enum.all?(pairs, fn {key, value} -> literal?(key) and literal?(value) end)

  defp literal?(values) when is_list(values), do: literal_list?(values)
  defp literal?(value) when is_atom(value) or is_binary(value), do: true
  defp literal?(value) when is_number(value) or is_boolean(value), do: true
  defp literal?(_value), do: false

  defp validate_each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end

  defp string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp string_list(_values), do: []

  defp blank?(value), do: value in [nil, ""]

  defp form_name({name, _meta, _args}) when is_atom(name), do: name
  defp form_name({{:., _meta, _call}, _call_meta, _args}), do: :remote_call
  defp form_name(value), do: value
end
