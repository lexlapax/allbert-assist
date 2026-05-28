defmodule AllbertAssist.Actions.Settings.SetActiveModelProfile do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :agent,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "set_active_model_profile",
    description: "Set the active model profile through Settings Central.",
    category: "settings",
    tags: ["settings", "models", "write"],
    schema: [
      profile: [type: :string, required: true],
      enable_assist: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    profile = field(params, :profile) || field(params, :model_profile) || "local"

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, model_profile} <- Settings.resolve_model_profile(profile),
         {:ok, writes} <-
           write_settings(profile, model_profile, params, context, permission_decision) do
      {:ok, completed(profile, model_profile, writes, permission_decision)}
    else
      false ->
        {:ok, denied(profile, permission_decision, :permission_denied)}

      {:error, reason} ->
        {:ok, denied(profile, permission_decision, reason)}
    end
  end

  defp write_settings(profile, model_profile, params, context, permission_decision) do
    action_context = action_context(context, permission_decision)

    with {:ok, model_setting} <- Settings.put("intent.model_profile", profile, action_context),
         {:ok, provider_setting} <-
           Settings.put("providers.#{model_profile.provider}.enabled", true, action_context),
         {:ok, assist_setting} <- maybe_write_assist(params, action_context) do
      {:ok, Enum.reject([model_setting, provider_setting, assist_setting], &is_nil/1)}
    end
  end

  defp maybe_write_assist(params, action_context) do
    case assist_value(params) do
      {:ok, value} -> Settings.put("intent.model_assist_enabled", value, action_context)
      :skip -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp completed(profile, model_profile, writes, permission_decision) do
    assist_write = Enum.find(writes, &(&1.key == "intent.model_assist_enabled"))

    %{
      message: completed_message(profile, model_profile, assist_write),
      status: :completed,
      permission_decision: permission_decision,
      profile: profile,
      provider: model_profile.provider,
      settings: writes,
      diagnostics: Enum.flat_map(writes, & &1.diagnostics),
      actions: [
        action(:completed, permission_decision, %{
          model_profile: profile,
          provider: model_profile.provider,
          provider_enabled: true,
          model_assist_enabled: assist_value_for_metadata(assist_write),
          audit_paths: audit_paths(writes)
        })
      ]
    }
  end

  defp denied(profile, permission_decision, reason) do
    %{
      message: "I could not set active model profile #{profile}: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      diagnostics: [%{code: :model_profile_write_failed, message: inspect(reason)}],
      actions: [
        action(:denied, permission_decision, %{
          model_profile: profile,
          error: reason
        })
      ]
    }
  end

  defp completed_message(profile, model_profile, nil) do
    "Active model profile set to #{profile}; provider #{model_profile.provider} enabled."
  end

  defp completed_message(profile, model_profile, assist_write) do
    "Active model profile set to #{profile}; provider #{model_profile.provider} enabled; model-assisted intent set to #{inspect(assist_write.value)}."
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "set_active_model_profile",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      settings_metadata: metadata
    }
  end

  defp assist_value(params) do
    value = field(params, :enable_assist)

    case {value, field(params, :model_assist_enabled)} do
      {nil, nil} -> :skip
      {nil, value} -> parse_bool(value)
      {value, _other} -> parse_bool(value)
    end
  end

  defp parse_bool(value) when is_boolean(value), do: {:ok, value}
  defp parse_bool("true"), do: {:ok, true}
  defp parse_bool("false"), do: {:ok, false}
  defp parse_bool(value), do: {:error, {:invalid_boolean, value}}

  defp assist_value_for_metadata(nil), do: :unchanged
  defp assist_value_for_metadata(setting), do: setting.value

  defp audit_paths(writes) do
    writes
    |> Enum.flat_map(& &1.diagnostics)
    |> Enum.flat_map(fn
      %{audit_path: audit_path} -> [audit_path]
      _diagnostic -> []
    end)
  end

  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.put(:permission_decision, permission_decision)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
