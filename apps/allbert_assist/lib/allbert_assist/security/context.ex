defmodule AllbertAssist.Security.Context do
  @moduledoc """
  Normalizes sparse runtime context for Security Central decisions.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Skills

  @doc "Normalize runtime context into the categories Security Central needs."
  @spec normalize(atom(), map()) :: map()
  def normalize(permission, context) when is_map(context) do
    request = request_context(context)

    %{
      permission: permission,
      actor: actor(request, context),
      channel: channel(request, context),
      session: session(request, context),
      action: action(context),
      skill: skill(context),
      resource: resource(context),
      secret_status: secret_status(context),
      external_content: external_content(context)
    }
  end

  defp request_context(%{request: request}) when is_map(request), do: request
  defp request_context(%{"request" => request}) when is_map(request), do: request
  defp request_context(context), do: context

  defp actor(request, context) do
    %{
      id:
        request_value(request, context, :operator_id) || request_value(request, context, :actor) ||
          "local",
      kind: :operator
    }
  end

  defp channel(request, context) do
    name = request_value(request, context, :channel) || :unknown

    %{
      name: name,
      trust: channel_trust(name)
    }
  end

  defp session(request, context) do
    %{
      id: request_value(request, context, :session_id),
      source_signal_id:
        request_value(request, context, :input_signal_id) ||
          request_value(request, context, :runner_requested_signal_id),
      request_id: request_value(request, context, :request_id)
    }
  end

  defp action(context) do
    metadata = Map.get(context, :action_metadata) || Map.get(context, "action_metadata") || %{}

    module =
      Map.get(context, :selected_action_module) || Map.get(context, "selected_action_module")

    name =
      Map.get(context, :selected_action) || Map.get(context, "selected_action") ||
        metadata_name(metadata)

    %{
      name: name,
      module: module,
      registered?: registered_action?(name, module),
      internal?: internal_action?(name),
      capability: action_capability(context)
    }
  end

  defp skill(context) do
    selected = Map.get(context, :selected_skill) || Map.get(context, "selected_skill")
    metadata = Map.get(context, :skill_metadata) || Map.get(context, "skill_metadata") || %{}

    selected
    |> registry_skill(context)
    |> case do
      {:ok, skill} ->
        skill_context(skill)

      {:error, :not_found} ->
        metadata_skill_context(selected, metadata, :not_found)

      :none ->
        metadata_skill_context(selected, metadata, :not_selected)
    end
  end

  defp registry_skill(nil, _context), do: :none

  defp registry_skill(selected, context) when is_binary(selected) do
    Skills.get(selected, context)
  rescue
    _exception -> {:error, :not_found}
  end

  defp registry_skill(_selected, _context), do: :none

  defp skill_context(skill) do
    %{
      name: skill.name,
      source_scope: skill.source_scope,
      source_path: skill.source_path,
      trust_status: skill.trust_status,
      lookup_status: :found,
      kind: skill.kind,
      permission: skill.permission,
      capability_contract: contract_summary(skill.capability_contract, skill.contract_validation),
      resources: resource_summary(skill)
    }
  end

  defp metadata_skill_context(selected, metadata, lookup_status) do
    %{
      name: selected || map_value(metadata, :selected_skill) || map_value(metadata, :name),
      source_scope: map_value(metadata, :source_scope),
      source_path: map_value(metadata, :source_path),
      trust_status: map_value(metadata, :trust_status),
      lookup_status: lookup_status,
      kind: map_value(metadata, :kind),
      permission: map_value(metadata, :permission),
      capability_contract: map_value(metadata, :capability_contract),
      resources: map_value(metadata, :resources) || []
    }
  end

  defp contract_summary(nil, _validation), do: nil

  defp contract_summary(contract, validation) do
    %{
      status: Map.get(contract, :status),
      actions: Map.get(contract, :actions, []),
      permissions: Map.get(contract, :permissions, []),
      confirmation: Map.get(contract, :confirmation),
      validation_status: map_value(validation, :status),
      execution_eligible?: map_value(validation, :execution_eligible?),
      validated_actions: map_value(validation, :actions) || [],
      validated_permissions: map_value(validation, :permissions) || []
    }
  end

  defp action_capability(context) do
    context
    |> map_value(:action_capability)
    |> Redactor.redact()
  end

  defp resource_summary(%{spec: %{resources: resources}}) when is_list(resources) do
    Enum.map(resources, fn resource ->
      %{
        kind: Map.get(resource, :kind),
        relative_path: Map.get(resource, :relative_path),
        executable?: Map.get(resource, :executable?, false)
      }
    end)
  end

  defp resource_summary(_skill), do: []

  defp resource(context) do
    resource = Map.get(context, :resource) || Map.get(context, "resource") || %{}

    %{
      kind: map_value(resource, :kind),
      path: map_value(resource, :path),
      external_uri: map_value(resource, :external_uri)
    }
  end

  defp secret_status(context) do
    redacted = Redactor.redact(context)

    %{
      references: secret_refs(context),
      raw_secret_present?: inspect(redacted) != inspect(context)
    }
  end

  defp external_content(context) do
    external = Map.get(context, :external_content) || Map.get(context, "external_content") || %{}
    source = map_value(external, :source)

    %{
      present?: source != nil || map_value(external, :present?) == true,
      source: source
    }
  end

  defp request_value(request, context, key) do
    map_value(request, key) || map_value(context, key)
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp metadata_name(metadata) do
    map_value(metadata, :name) || map_value(metadata, :action_name)
  end

  defp registered_action?(nil, nil), do: false
  defp registered_action?(name, nil) when is_binary(name), do: registered_action?(name, "")

  defp registered_action?(_name, module) when is_atom(module),
    do: Registry.registered_module?(module)

  defp registered_action?(name, _module) when is_binary(name) do
    case Registry.resolve(name) do
      {:ok, _module} -> true
      {:error, _reason} -> false
    end
  end

  defp registered_action?(_name, _module), do: false

  defp internal_action?("record_trace"), do: true
  defp internal_action?(_name), do: false

  defp channel_trust(name) when name in [:cli, "cli", :live_view, "live_view", :test, "test"],
    do: :local

  defp channel_trust(:unknown), do: :unknown
  defp channel_trust("unknown"), do: :unknown
  defp channel_trust(_name), do: :future_remote

  defp secret_refs(term) do
    term
    |> secret_refs(MapSet.new())
    |> MapSet.to_list()
  end

  defp secret_refs("secret://" <> _rest = ref, refs), do: MapSet.put(refs, ref)

  defp secret_refs(%_{} = struct, refs) do
    struct
    |> Map.from_struct()
    |> secret_refs(refs)
  end

  defp secret_refs(%{} = map, refs) do
    Enum.reduce(map, refs, fn {_key, value}, acc -> secret_refs(value, acc) end)
  end

  defp secret_refs(list, refs) when is_list(list) do
    Enum.reduce(list, refs, &secret_refs/2)
  end

  defp secret_refs(_term, refs), do: refs
end
