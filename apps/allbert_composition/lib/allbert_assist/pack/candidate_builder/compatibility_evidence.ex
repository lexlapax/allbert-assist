defmodule AllbertAssist.Pack.CandidateBuilder.CompatibilityEvidence do
  @moduledoc false

  alias AllbertAssist.Objectives.CanonicalJSON

  alias AllbertAssist.Pack.{
    ChildSpecProjection,
    CompatibilityDiagnostic,
    OwnerRef,
    PathSegment,
    ValidationDiagnostic
  }

  @child_args_digest_domain "allbert.pack.child_spec.args.v1\0"

  @spec build([map()]) ::
          {:ok, [CompatibilityDiagnostic.t()]} | {:error, [ValidationDiagnostic.t()]}
  def build(plugins) when is_list(plugins) do
    {:ok,
     Enum.flat_map(plugins, fn
       %{status: :disabled} = plugin -> [disabled_diagnostic(plugin)]
       %{status: :enabled, children: :ignore} -> []
       %{status: :enabled} = plugin -> [child_diagnostic(plugin)]
     end)}
  rescue
    _ -> invalid(:invalid_compatibility_evidence)
  end

  def build(_plugins), do: invalid(:invalid_plugin_evidence)

  defp child_diagnostic(plugin) when is_map(plugin.children) do
    spec = Supervisor.child_spec(plugin.children, [])

    %CompatibilityDiagnostic{
      schema_version: 1,
      code: :child_spec,
      severity: :warning,
      path: path(plugin.plugin_id, "children"),
      owner: owner(plugin),
      detail: %{child_spec: project_child_spec(spec)}
    }
  end

  defp disabled_diagnostic(plugin) do
    %CompatibilityDiagnostic{
      schema_version: 1,
      code: :disabled_plugin,
      severity: :warning,
      path: path(plugin.plugin_id, "status"),
      owner: owner(plugin),
      detail: %{source: plugin.source, status: :disabled}
    }
  end

  defp owner(plugin) do
    %OwnerRef{
      schema_version: 1,
      kind: if(is_nil(plugin.module), do: :declared_pack, else: :legacy_plugin),
      id: plugin.plugin_id
    }
  end

  defp path(plugin_id, field) do
    [
      %PathSegment{schema_version: 1, kind: :field, value: "plugins"},
      %PathSegment{schema_version: 1, kind: :identity, value: plugin_id},
      %PathSegment{schema_version: 1, kind: :field, value: field}
    ]
  end

  defp project_child_spec(spec) do
    {start_module, start_function, start_arity, start_args_sha256} = project_start(spec[:start])

    %ChildSpecProjection{
      schema_version: 1,
      id: child_id(spec[:id]),
      start_module: start_module,
      start_function: start_function,
      start_arity: start_arity,
      start_args_sha256: start_args_sha256,
      restart: restart(spec[:restart]),
      shutdown: shutdown(spec[:shutdown]),
      type: child_type(spec[:type])
    }
  end

  defp project_start({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    normalized = strict(args)

    {module_name(module), Atom.to_string(function), length(args),
     sha256(@child_args_digest_domain <> CanonicalJSON.encode(normalized))}
  end

  defp project_start(nil), do: {nil, nil, nil, nil}

  defp child_id(nil), do: nil
  defp child_id(value) when is_integer(value) or (is_binary(value) and value != ""), do: value
  defp child_id(value) when is_atom(value), do: module_name(value)

  defp child_id(value) when is_tuple(value),
    do: %{"tuple" => value |> Tuple.to_list() |> Enum.map(&child_id/1)}

  defp child_id(_value), do: raise(ArgumentError)

  defp restart(nil), do: nil

  defp restart(value) when value in [:permanent, :transient, :temporary],
    do: Atom.to_string(value)

  defp restart(_value), do: raise(ArgumentError)

  defp shutdown(nil), do: nil
  defp shutdown(value) when value in [:brutal_kill, :infinity], do: Atom.to_string(value)
  defp shutdown(value) when is_integer(value) and value >= 0, do: value
  defp shutdown(_value), do: raise(ArgumentError)

  defp child_type(nil), do: nil
  defp child_type(value) when value in [:worker, :supervisor], do: Atom.to_string(value)
  defp child_type(_value), do: raise(ArgumentError)

  defp strict(nil), do: nil
  defp strict(value) when is_boolean(value) or is_number(value), do: value

  defp strict(value) when is_binary(value),
    do: if(Path.type(value) == :absolute, do: raise(ArgumentError), else: value)

  defp strict(value) when is_atom(value), do: module_name(value)
  defp strict(value) when is_list(value), do: Enum.map(value, &strict/1)

  defp strict(value) when is_tuple(value),
    do: %{"tuple" => value |> Tuple.to_list() |> Enum.map(&strict/1)}

  defp strict(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      key = strict_key(key)
      if Map.has_key?(acc, key), do: raise(ArgumentError)
      Map.put(acc, key, strict(nested))
    end)
  end

  defp strict(_value), do: raise(ArgumentError)

  defp strict_key(value) when is_binary(value),
    do: if(Path.type(value) == :absolute, do: raise(ArgumentError), else: value)

  defp strict_key(value) when is_atom(value), do: module_name(value)
  defp strict_key(_value), do: raise(ArgumentError)

  defp module_name(value), do: value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp invalid(reason),
    do:
      {:error,
       [
         %ValidationDiagnostic{
           schema_version: 1,
           code: :invalid_value,
           path: [%PathSegment{schema_version: 1, kind: :field, value: "plugins"}],
           owner: nil,
           detail: %{reason: reason}
         }
       ]}
end
