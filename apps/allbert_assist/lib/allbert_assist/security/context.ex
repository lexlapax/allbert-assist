defmodule AllbertAssist.Security.Context do
  @moduledoc """
  Normalizes sparse runtime context for Security Central decisions.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Coding.CommandGrants
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.SafeTerm
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
      parent: parent(context),
      skill: skill(context),
      resource: resource(context),
      coding: coding(context),
      voice: voice(context),
      advisory: advisory(context),
      secret_status: secret_status(context),
      external_content: external_content(context)
    }
  end

  defp request_context(%{request: request}) when is_map(request), do: request
  defp request_context(%{"request" => request}) when is_map(request), do: request
  defp request_context(context), do: context

  defp actor(request, context) do
    actor =
      trusted_context_value(context, :operator_id) || trusted_context_value(context, :actor) ||
        map_value(request, :operator_id) || map_value(request, :actor)

    %{
      id: actor_id(actor) || "local",
      kind: :operator
    }
  end

  defp channel(request, context) do
    name =
      trusted_context_value(context, :channel)
      |> Kernel.||(map_value(request, :channel))
      |> channel_name()

    %{
      name: name || :unknown,
      trust: channel_trust(name)
    }
  end

  defp session(request, context) do
    %{
      id: trusted_context_value(context, :session_id) || map_value(request, :session_id),
      source_signal_id:
        trusted_context_value(context, :input_signal_id) ||
          trusted_context_value(context, :runner_requested_signal_id) ||
          map_value(request, :input_signal_id) ||
          map_value(request, :runner_requested_signal_id),
      request_id: trusted_context_value(context, :request_id) || map_value(request, :request_id)
    }
    |> Map.put(:main?, main_session?(request, context))
  end

  defp coding(context) do
    coding = context |> map_value(:coding) |> map_or_empty()

    %{}
    |> maybe_put(:approval_mode, map_value(coding, :approval_mode))
    |> maybe_put(:default_approval_mode, map_value(coding, :default_approval_mode))
    |> maybe_put(:pi_mode_enabled, map_value(coding, :pi_mode_enabled))
    |> maybe_put(:pi_mode_enabled?, map_value(coding, :pi_mode_enabled?))
    |> maybe_put(:pi_mode, map_value(coding, :pi_mode))
    |> maybe_put(:trusted_operator_id, map_value(coding, :trusted_operator_id))
    |> maybe_put(:command_grant_ref, command_grant_ref(coding))
    |> maybe_put(:generated_code_session?, map_value(coding, :generated_code_session?))
    |> maybe_put(:channel_originated?, map_value(context, :channel_originated?))
    |> maybe_put(:scheduled?, map_value(context, :scheduled?))
  end

  defp command_grant_ref(coding) do
    cond do
      is_map(map_value(coding, :command_grant_ref)) ->
        map_value(coding, :command_grant_ref)

      is_map(map_value(coding, :command_params)) ->
        case CommandGrants.canonical_ref(map_value(coding, :command_params)) do
          {:ok, ref} -> CommandGrants.redacted_ref(ref)
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  end

  defp main_session?(request, context) do
    session = map_value(context, :session) || map_value(request, :session) || %{}

    map_value(session, :main?) == true or map_value(context, :main_session?) == true or
      map_value(request, :main_session?) == true or
      map_value(context, :session_kind) in [:main, "main"] or
      map_value(request, :session_kind) in [:main, "main"]
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(%{"id" => id}), do: id
  defp actor_id(actor) when is_binary(actor) or is_atom(actor), do: actor
  defp actor_id(_actor), do: nil

  defp channel_name(%{name: name}), do: name
  defp channel_name(%{"name" => name}), do: name
  defp channel_name(channel) when is_binary(channel) or is_atom(channel), do: channel
  defp channel_name(_channel), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

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

  defp parent(context) do
    parent = Map.get(context, :parent) || Map.get(context, "parent") || %{}

    %{
      permission:
        map_value(parent, :permission) || map_value(context, :parent_permission) ||
          map_value(context, :target_permission),
      approved?:
        map_value(parent, :approved?) == true or
          map_value(parent, :status) in [:approved, "approved"] or
          map_value(context, :parent_approved?) == true,
      confirmation_id:
        map_value(parent, :confirmation_id) || map_value(context, :parent_confirmation_id)
    }
  end

  defp resource_summary(%{spec: %{resources: resources}}) when is_list(resources) do
    resources
    |> SafeTerm.filter_list(&is_map/1)
    |> Enum.map(fn resource ->
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

  defp voice(context) do
    model_profile = map_value(context, :model_profile) || %{}
    media = map_value(model_profile, :media) || map_value(context, :media) || %{}

    %{
      provider_deployment_mode:
        map_value(context, :provider_deployment_mode) || map_value(context, :deployment_mode) ||
          map_value(media, :deployment_mode),
      media: Redactor.redact(media)
    }
  end

  defp advisory(context) do
    advisory = Map.get(context, :advisory) || Map.get(context, "advisory") || %{}
    output = Map.get(context, :advisory_output) || Map.get(context, "advisory_output")
    source = map_value(advisory, :source) || map_value(output, :source)

    %{
      present?:
        source != nil or output != nil or map_value(advisory, :present?) == true or
          map_value(context, :advisory_output?) == true,
      source: source,
      provider: map_value(advisory, :provider) || map_value(output, :provider)
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

  defp map_value(map, key) when is_map(map), do: Maps.field_truthy(map, key)

  defp map_value(_map, _key), do: nil

  defp trusted_context_value(context, key) when is_map(context) do
    context
    |> Map.drop([:request, "request"])
    |> map_value(key)
  end

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

  defp channel_trust(name)
       when name in [:cli, "cli", :live_view, "live_view", :tui, "tui", :test, "test"],
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
    list
    |> SafeTerm.to_list()
    |> Enum.reduce(refs, &secret_refs/2)
  end

  defp secret_refs(_term, refs), do: refs
end
