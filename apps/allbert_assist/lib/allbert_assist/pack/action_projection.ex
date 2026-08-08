defmodule AllbertAssist.Pack.ActionProjection.Candidate do
  @moduledoc false

  @enforce_keys [:effective, :plugin_declarations, :alias_sources]
  defstruct @enforce_keys

  @type projection :: %{
          required(:legacy_index) => pos_integer() | nil,
          required(:module) => module(),
          required(:name) => String.t(),
          required(:normalized_capability) => map(),
          required(:input_schema_sha256) => String.t(),
          required(:output_schema_sha256) => String.t(),
          required(:app_id) => atom() | nil,
          required(:plugin_id) => String.t() | nil,
          optional(:disposition) =>
            :effective | :static_module | :static_name | :duplicate_plugin_name
        }

  @type t :: %__MODULE__{
          effective: [projection()],
          plugin_declarations: [projection()],
          alias_sources: [projection()]
        }
end

defmodule AllbertAssist.Pack.ActionProjection do
  @moduledoc """
  Pure projection of compiled action declarations and captured owner metadata.

  This module is the pre-finalization action source for Pack candidate assembly.
  It never reads the live public action Registry or a finalized Pack snapshot.
  """

  alias AllbertAssist.Action
  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Pack.{ActionCatalog, PathSegment, ValidationDiagnostic}
  alias AllbertAssist.Pack.ActionProjection.Candidate

  @spec static() :: {:ok, [map()]} | {:error, [ValidationDiagnostic.t()]}
  def static do
    with {:ok, modules} <- ActionCatalog.residual_modules() do
      modules
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {module, legacy_index}, {:ok, projections} ->
        case project_module(module, legacy_index, nil, nil) do
          {:ok, projection} -> {:cont, {:ok, [projection | projections]}}
          {:error, diagnostic} -> {:halt, {:error, [diagnostic]}}
        end
      end)
      |> reverse_projections()
    else
      {:error, reason} -> {:error, [diagnostic(reason)]}
    end
  end

  @spec build([map()], [map()]) ::
          {:ok, Candidate.t()} | {:error, [ValidationDiagnostic.t()]}
  def build(app_entries, plugin_entries)
      when is_list(app_entries) and is_list(plugin_entries) do
    with {:ok, static} <- static() do
      build(static, app_entries, plugin_entries)
    end
  end

  def build(_app_entries, _plugin_entries), do: invalid(:invalid_candidate_projection)

  @spec build([map()], [map()], [map()]) ::
          {:ok, Candidate.t()} | {:error, [ValidationDiagnostic.t()]}
  def build(static, app_entries, plugin_entries)
      when is_list(static) and is_list(app_entries) and is_list(plugin_entries) do
    do_build(static, app_entries, plugin_entries, :complete)
  end

  def build(_static, _app_entries, _plugin_entries),
    do: invalid(:invalid_candidate_projection)

  @doc "Project a captured metadata subset without requiring the complete production token sequence."
  @spec metadata([map()], [map()]) ::
          {:ok, Candidate.t()} | {:error, [ValidationDiagnostic.t()]}
  def metadata(app_entries, plugin_entries)
      when is_list(app_entries) and is_list(plugin_entries) do
    with {:ok, static} <- static() do
      do_build(static, app_entries, plugin_entries, :metadata_subset)
    end
  end

  def metadata(_app_entries, _plugin_entries), do: invalid(:invalid_candidate_projection)

  defp do_build(static, app_entries, plugin_entries, mode) do
    with {:ok, static} <- validate_static(static),
         {:ok, app_memberships} <- memberships(app_entries, :app),
         {:ok, plugin_memberships} <- memberships(enabled_plugins(plugin_entries), :plugin),
         {:ok, effective_static} <- enrich_static(static, app_memberships, plugin_memberships),
         {:ok, declarations} <-
           plugin_declarations(plugin_entries, app_memberships, plugin_memberships) do
      assemble(effective_static, declarations, mode)
    end
  end

  defp validate_static(static) do
    static
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {projection, expected_index}, {:ok, acc} ->
      with %{
             legacy_index: ^expected_index,
             registry_order: ^expected_index,
             module: module,
             name: name
           } <- projection,
           true <- is_atom(module) and is_binary(name) and name == normalize_name(name),
           true <- is_map(Map.get(projection, :normalized_capability)),
           true <- sha256?(Map.get(projection, :input_schema_sha256)),
           true <- sha256?(Map.get(projection, :output_schema_sha256)) do
        {:cont, {:ok, [projection | acc]}}
      else
        _ -> {:halt, invalid(:invalid_static_projection)}
      end
    end)
    |> reverse_projections()
  end

  defp memberships(entries, :app),
    do: membership_index(entries, :app_id, :actions, :ambiguous_app_action_membership)

  defp memberships(entries, :plugin),
    do: membership_index(entries, :plugin_id, :actions, :ambiguous_plugin_action_membership)

  defp membership_index(entries, id_key, actions_key, ambiguity_code) do
    entries
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      id = entry_value(entry, id_key)
      actions = entry_value(entry, actions_key, [])

      if valid_owner_id?(id) and is_list(actions) and Enum.all?(actions, &is_atom/1) do
        memberships =
          Enum.reduce(actions, acc, fn module, memberships ->
            Map.update(memberships, module, [id], &[id | &1])
          end)

        {:cont, {:ok, memberships}}
      else
        {:halt, invalid(:invalid_metadata_entry)}
      end
    end)
    |> then(fn
      {:ok, memberships} ->
        if Enum.any?(memberships, fn {_module, owners} ->
             owners |> Enum.uniq() |> length() > 1
           end) do
          invalid(ambiguity_code)
        else
          {:ok, Map.new(memberships, fn {module, [owner | _]} -> {module, owner} end)}
        end

      error ->
        error
    end)
  end

  defp enabled_plugins(entries),
    do: Enum.filter(entries, &(entry_value(&1, :status) == :enabled))

  defp enrich_static(static, app_memberships, plugin_memberships) do
    static_modules = MapSet.new(Enum.map(static, & &1.module))

    dangling_modules =
      (Map.keys(app_memberships) ++ Map.keys(plugin_memberships))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(static_modules, &1))

    if Enum.any?(dangling_modules, fn module -> not Map.has_key?(plugin_memberships, module) end) do
      invalid(:dangling_app_action_membership)
    else
      {:ok,
       Enum.map(static, fn projection ->
         app_id = Map.get(app_memberships, projection.module)
         plugin_id = Map.get(plugin_memberships, projection.module)

         projection
         |> Map.put(:app_id, app_id)
         |> Map.put(:plugin_id, plugin_id)
         |> Map.update!(:normalized_capability, fn capability ->
           capability
           |> Map.put(:app_id, app_id)
           |> Map.put(:plugin_id, plugin_id)
         end)
       end)}
    end
  end

  defp plugin_declarations(plugin_entries, app_memberships, plugin_memberships) do
    plugin_entries
    |> Enum.reduce_while({:ok, []}, fn plugin, {:ok, declarations} ->
      plugin_id = entry_value(plugin, :plugin_id)
      actions = entry_value(plugin, :actions, [])

      cond do
        not valid_owner_id?(plugin_id) or not is_list(actions) or
            not Enum.all?(actions, &is_atom/1) ->
          {:halt, invalid(:invalid_metadata_entry)}

        entry_value(plugin, :status) != :enabled ->
          {:cont, {:ok, declarations}}

        true ->
          result =
            Enum.reduce_while(actions, {:ok, declarations}, fn module, {:ok, acc} ->
              with ^plugin_id <- Map.get(plugin_memberships, module),
                   {:ok, projection} <-
                     project_module(module, nil, Map.get(app_memberships, module), plugin_id) do
                {:cont, {:ok, [projection | acc]}}
              else
                nil -> {:halt, invalid(:dangling_plugin_action_membership)}
                {:error, diagnostic} -> {:halt, {:error, [diagnostic]}}
                _ -> {:halt, invalid(:ambiguous_plugin_action_membership)}
              end
            end)

          case result do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
      end
    end)
    |> reverse_projections()
  end

  defp assemble(effective_static, declarations, mode) do
    static_modules = MapSet.new(Enum.map(effective_static, & &1.module))
    static_names = MapSet.new(Enum.map(effective_static, & &1.name))
    name_counts = declarations |> Enum.map(& &1.name) |> Enum.frequencies()

    declarations =
      Enum.map(declarations, fn declaration ->
        disposition =
          cond do
            MapSet.member?(static_modules, declaration.module) -> :static_module
            MapSet.member?(static_names, declaration.name) -> :static_name
            Map.fetch!(name_counts, declaration.name) > 1 -> :duplicate_plugin_name
            true -> :effective
          end

        Map.put(declaration, :disposition, disposition)
      end)

    effective_plugins =
      declarations
      |> Enum.filter(&(&1.disposition == :effective))
      |> Enum.with_index(length(effective_static) + 1)
      |> Enum.map(fn {projection, legacy_index} ->
        Map.put(projection, :legacy_index, legacy_index)
      end)

    effective = effective_static ++ effective_plugins
    expected_orders = if effective == [], do: [], else: Enum.to_list(1..length(effective))

    if mode == :metadata_subset or Enum.map(effective, & &1.registry_order) == expected_orders do
      {:ok,
       %Candidate{
         effective: effective,
         plugin_declarations: declarations,
         alias_sources: Enum.reject(declarations, &(&1.disposition == :effective))
       }}
    else
      invalid(:invalid_registry_order)
    end
  end

  defp project_module(module, legacy_index, app_id, plugin_id) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :name, 0),
         registry_order <- module_registry_order(module),
         true <-
           (is_integer(registry_order) and registry_order >= 0) or
             (is_nil(legacy_index) and is_nil(registry_order)),
         {:ok, attrs} <- module_capability_attrs(module) do
      name = module.name()

      if is_binary(name) and name == normalize_name(name) do
        capability =
          module
          |> Capability.new(attrs)
          |> Map.from_struct()
          |> Map.take([
            :app_id,
            :confirmation,
            :execution_mode,
            :exposure,
            :notes,
            :permission,
            :plugin_id,
            :resumable?,
            :retry_safety,
            :skill_backed?
          ])
          |> Map.put(:app_id, app_id)
          |> Map.put(:plugin_id, plugin_id)

        {:ok,
         %{
           legacy_index: legacy_index,
           registry_order: registry_order,
           module: module,
           name: name,
           normalized_capability: capability,
           input_schema_sha256: schema_sha256(module, :schema),
           output_schema_sha256: schema_sha256(module, :output_schema),
           app_id: app_id,
           plugin_id: plugin_id
         }}
      else
        {:error, diagnostic(:invalid_action_name)}
      end
    else
      _ -> {:error, diagnostic(:invalid_action_module)}
    end
  rescue
    _exception -> {:error, diagnostic(:invalid_action_module)}
  catch
    :exit, _reason -> {:error, diagnostic(:invalid_action_module)}
  end

  defp project_module(_module, _legacy_index, _app_id, _plugin_id),
    do: {:error, diagnostic(:invalid_action_module)}

  defp module_capability_attrs(module) do
    with true <- function_exported?(module, :capability, 0) do
      module |> apply(:capability, []) |> Action.validate_capability()
    else
      false -> {:error, :missing_action_capability}
    end
  end

  defp module_registry_order(module) do
    if function_exported?(module, :registry_order, 0), do: module.registry_order(), else: nil
  end

  defp schema_sha256(module, function) do
    value = if function_exported?(module, function, 0), do: apply(module, function, []), else: nil

    value
    |> normalize()
    |> CanonicalJSON.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize(nil), do: nil

  defp normalize(value)
       when is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value),
       do: value

  defp normalize(%Regex{} = regex), do: %{"$regex" => Regex.source(regex), "opts" => regex.opts}

  defp normalize(%MapSet{} = set),
    do: set |> MapSet.to_list() |> Enum.map(&normalize/1) |> Enum.sort()

  defp normalize(%_{} = struct),
    do:
      struct
      |> Map.from_struct()
      |> normalize()
      |> Map.put("$struct", module_name(struct.__struct__))

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {normalize_key(key), normalize(nested)} end)

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> normalize()}

  defp normalize(value) when is_function(value),
    do: %{
      "$function" => module_name(elem(:erlang.fun_info(value, :module), 1)),
      "name" => value |> :erlang.fun_info(:name) |> elem(1) |> Atom.to_string(),
      "arity" => value |> :erlang.fun_info(:arity) |> elem(1)
    }

  defp normalize(value) when is_pid(value), do: "<PID>"
  defp normalize(value) when is_reference(value), do: "<REFERENCE>"
  defp normalize(value) when is_port(value), do: "<PORT>"
  defp normalize(value) when is_atom(value), do: module_name(value)
  defp normalize(value), do: inspect(value)

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: module_name(key)
  defp normalize_key(key), do: key |> normalize() |> inspect()

  defp normalize_name(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp module_name(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp entry_value(entry, key, default \\ nil)
  defp entry_value(entry, key, default) when is_map(entry), do: Map.get(entry, key, default)
  defp entry_value(_entry, _key, default), do: default

  defp valid_owner_id?(value) when is_atom(value), do: value not in [nil, true, false]
  defp valid_owner_id?(value) when is_binary(value), do: value != ""
  defp valid_owner_id?(_value), do: false
  defp sha256?(value), do: is_binary(value) and value =~ ~r/^[0-9a-f]{64}$/

  defp reverse_projections({:ok, projections}), do: {:ok, Enum.reverse(projections)}
  defp reverse_projections(error), do: error

  defp invalid(reason), do: {:error, [diagnostic(reason)]}

  defp diagnostic(reason) do
    %ValidationDiagnostic{
      schema_version: 1,
      code: :invalid_value,
      path: [%PathSegment{schema_version: 1, kind: :field, value: "actions"}],
      owner: nil,
      detail: %{reason: reason}
    }
  end
end
