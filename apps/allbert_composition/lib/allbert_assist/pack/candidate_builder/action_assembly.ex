defmodule AllbertAssist.Pack.CandidateBuilder.ActionAssembly do
  @moduledoc false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Objectives.CanonicalJSON

  alias AllbertAssist.Pack.{
    ActionBinding,
    CompatibilityAlias,
    PathSegment,
    Row,
    RowSchemas,
    Target,
    ValidationDiagnostic
  }

  alias AllbertAssist.Pack.CandidateBuilder.RowFamilies

  @residual_owner_id "allbert_assist"
  @alias_digest_domain "allbert.pack.alias.authority.v1\0"

  @spec build([map()], [map()], keyword()) ::
          {:ok,
           %{
             bindings: [ActionBinding.t()],
             aliases: [CompatibilityAlias.t()],
             diagnostics: [],
             families: RowFamilies.t()
           }}
          | {:error, [ValidationDiagnostic.t()]}
  def build(apps, plugins, opts \\ [])

  def build(apps, plugins, opts) when is_list(apps) and is_list(plugins) and is_list(opts) do
    with {:ok, static} <- static_projection(opts),
         {:ok, projection} <- Registry.candidate_projection(static, apps, plugins),
         {:ok, bindings} <- bindings(projection.effective, length(static)),
         {:ok, rows, aliases} <- rows_and_aliases(projection.plugin_declarations, bindings) do
      families = %{RowFamilies.empty() | actions: rows}

      {:ok, %{bindings: bindings, aliases: aliases, diagnostics: [], families: families}}
    end
  rescue
    _ -> invalid(:invalid_action_assembly)
  end

  def build(_apps, _plugins, _opts), do: invalid(:invalid_action_input)

  defp static_projection(opts) do
    case Keyword.fetch(opts, :static_projection) do
      {:ok, projection} when is_list(projection) -> {:ok, projection}
      :error -> Registry.static_projection()
      _ -> invalid(:invalid_static_projection)
    end
  end

  defp bindings(projections, static_count) do
    projections
    |> Enum.with_index(1)
    |> Enum.map(fn {projection, index} -> build_binding(projection, index <= static_count) end)
    |> then(&{:ok, &1})
  end

  defp build_binding(projection, static?) do
    source_lane = if static?, do: :native_static, else: :legacy_plugin

    m0_projection = %{
      "index" => projection.legacy_index,
      "name" => projection.name,
      "module" => module_name(projection.module),
      "source_bucket" => if(source_lane == :native_static, do: "static", else: "plugin_append"),
      "capability" => m0_normalize(projection.normalized_capability),
      "input_schema_sha256" => projection.input_schema_sha256,
      "output_schema_sha256" => projection.output_schema_sha256
    }

    %ActionBinding{
      schema_version: 1,
      module: projection.module,
      name: projection.name,
      source_lane: source_lane,
      legacy_index: projection.legacy_index,
      registry_order: nil,
      normalized_capability: projection.normalized_capability,
      m0_row_sha256: sha256(CanonicalJSON.encode(m0_projection)),
      input_schema_sha256: projection.input_schema_sha256,
      output_schema_sha256: projection.output_schema_sha256
    }
  end

  defp rows_and_aliases(declarations, bindings) do
    static = Enum.filter(bindings, &(&1.source_lane == :native_static))
    static_by_module = Map.new(static, &{&1.module, &1})
    static_by_name = Map.new(static, &{&1.name, &1})
    plugin_by_module = Map.new(bindings -- static, &{&1.module, &1})

    initial_rows = %{
      @residual_owner_id => Enum.map(static, &action_row(@residual_owner_id, &1, false))
    }

    declarations
    |> Enum.reduce_while({:ok, initial_rows, []}, fn declaration, {:ok, rows, aliases} ->
      case declaration_binding(declaration, static_by_module, static_by_name, plugin_by_module) do
        {:ok, binding, alias?} ->
          row = action_row(declaration.plugin_id, binding, alias?)
          rows = Map.update(rows, declaration.plugin_id, [row], &(&1 ++ [row]))

          aliases =
            if alias?,
              do: aliases ++ [action_alias(declaration.plugin_id, binding)],
              else: aliases

          {:cont, {:ok, rows, aliases}}

        :error ->
          {:halt, invalid(:unresolved_action_declaration)}
      end
    end)
    |> then(fn
      {:ok, rows, aliases} ->
        aliases = aliases |> Enum.chunk_by(& &1.owner_id) |> Enum.flat_map(&Enum.reverse/1)
        {:ok, rows, aliases}

      error ->
        error
    end)
  end

  defp declaration_binding(
         %{disposition: :effective, module: module},
         _static_modules,
         _static_names,
         plugins
       ),
       do: fetch_binding(plugins, module, false)

  defp declaration_binding(
         %{disposition: :static_module, module: module},
         static_modules,
         _static_names,
         _plugins
       ),
       do: fetch_binding(static_modules, module, true)

  defp declaration_binding(
         %{disposition: :static_name, name: name},
         _static_modules,
         static_names,
         _plugins
       ),
       do: fetch_binding(static_names, name, true)

  defp declaration_binding(
         %{disposition: :duplicate_plugin_name},
         _static_modules,
         _static_names,
         _plugins
       ),
       do: :error

  defp declaration_binding(_declaration, _static_modules, _static_names, _plugins), do: :error

  defp fetch_binding(index, key, alias?) do
    case Map.fetch(index, key) do
      {:ok, %ActionBinding{} = binding} -> {:ok, binding, alias?}
      :error -> :error
    end
  end

  defp action_row(owner_id, binding, alias?) do
    payload_without_digest = %{
      "module" => module_name(binding.module),
      "name" => binding.name,
      "registry_order" => binding.registry_order
    }

    authority = action_authority(binding)
    placeholder = Map.put(payload_without_digest, "binding_sha256", String.duplicate("0", 64))

    digest =
      RowSchemas.reference_digest_for!(:action_ref_v1, %RowSchemas.Input{
        payload: placeholder,
        source_authority: authority
      })

    normalized =
      RowSchemas.normalize!(:action_ref_v1, %RowSchemas.Input{
        payload: Map.put(payload_without_digest, "binding_sha256", digest),
        source_authority: authority
      })

    %Row{
      schema_version: 1,
      kind: :actions,
      owner_id: owner_id,
      identity: %{namespace: :action_name, value: binding.name},
      order: %{
        namespace: if(alias?, do: :alias_target, else: :legacy_index),
        value: binding.legacy_index
      },
      payload_schema: :action_ref_v1,
      payload: RowSchemas.canonical_projection(normalized),
      source_authority: RowSchemas.source_authority_projection(normalized),
      m0_payload_sha256: if(alias?, do: nil, else: binding.m0_row_sha256)
    }
  end

  defp action_alias(owner_id, binding) do
    %CompatibilityAlias{
      schema_version: 1,
      kind: :legacy_plugin,
      owner_id: owner_id,
      target: %Target{
        schema_version: 1,
        kind: :action,
        owner_id: @residual_owner_id,
        identity: binding.name
      },
      module: binding.module,
      authority_sha256:
        sha256(@alias_digest_domain <> CanonicalJSON.encode(action_authority(binding)))
    }
  end

  defp action_authority(binding) do
    %{
      "kind" => "action",
      "module" => module_name(binding.module),
      "name" => binding.name,
      "normalized_capability" => m0_normalize(binding.normalized_capability),
      "input_schema_sha256" => binding.input_schema_sha256,
      "output_schema_sha256" => binding.output_schema_sha256
    }
  end

  defp m0_normalize(nil), do: nil

  defp m0_normalize(value) when is_boolean(value) or is_number(value) or is_binary(value),
    do: value

  defp m0_normalize(value) when is_atom(value), do: module_name(value)
  defp m0_normalize(value) when is_list(value), do: Enum.map(value, &m0_normalize/1)

  defp m0_normalize(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> m0_normalize()}

  defp m0_normalize(%_{} = value) do
    value
    |> Map.from_struct()
    |> m0_normalize()
    |> Map.put("$struct", module_name(value.__struct__))
  end

  defp m0_normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {m0_key(key), m0_normalize(nested)} end)
  end

  defp m0_normalize(value), do: inspect(value)

  defp m0_key(value) when is_binary(value), do: value
  defp m0_key(value) when is_atom(value), do: module_name(value)
  defp m0_key(value), do: value |> m0_normalize() |> inspect()

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp module_name(value) when is_atom(value) do
    value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp invalid(reason),
    do:
      {:error,
       [
         %ValidationDiagnostic{
           schema_version: 1,
           code: :invalid_value,
           path: [%PathSegment{schema_version: 1, kind: :field, value: "actions"}],
           owner: nil,
           detail: %{reason: reason}
         }
       ]}
end
