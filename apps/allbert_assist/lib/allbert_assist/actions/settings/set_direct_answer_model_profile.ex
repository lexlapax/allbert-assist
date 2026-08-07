defmodule AllbertAssist.Actions.Settings.SetDirectAnswerModelProfile do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :agent,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "set_direct_answer_model_profile",
    description: "Select the DirectAnswer profile without changing the global primary model.",
    category: "settings",
    tags: ["settings", "models", "direct_answer", "write"],
    schema: [
      profile: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.DirectAnswerSelection

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    profile = Maps.field_truthy(params, :profile)

    with true <- PermissionGate.allowed?(permission_decision),
         :ok <- validate_profile(profile),
         {:ok, selection} <-
           DirectAnswerSelection.select(
             profile,
             action_context(context, permission_decision)
           ) do
      {:ok, completed(selection, permission_decision)}
    else
      false -> denied(profile, permission_decision, :permission_denied)
      {:error, reason} -> denied(profile, permission_decision, reason)
    end
  end

  defp validate_profile(profile) when is_binary(profile) and profile != "", do: :ok
  defp validate_profile(_profile), do: {:error, :invalid_model_profile}

  defp completed(selection, permission_decision) do
    %{
      message:
        "DirectAnswer profile set to #{selection.profile}; provider #{selection.provider} enabled; global primary unchanged.",
      status: :completed,
      permission_decision: permission_decision,
      profile: selection.profile,
      provider: selection.provider,
      chain: selection.chain,
      settings: selection.settings,
      disclosure: selection.disclosure,
      diagnostics: Enum.flat_map(selection.settings, & &1.diagnostics),
      actions: [
        %{
          name: "set_direct_answer_model_profile",
          status: :completed,
          permission: :settings_write,
          permission_decision: permission_decision,
          settings_metadata: %{
            direct_answer_model_profile: selection.profile,
            provider: selection.provider,
            provider_enabled: true,
            chain: selection.chain,
            global_primary: :unchanged,
            disclosure: selection.disclosure,
            audit_paths: audit_paths(selection.settings)
          }
        }
      ]
    }
  end

  defp denied(profile, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not set DirectAnswer profile #{profile}: #{inspect(reason)}",
       status: :denied,
       permission_decision: permission_decision,
       diagnostics: [%{code: :direct_answer_profile_write_failed, message: inspect(reason)}],
       actions: [
         %{
           name: "set_direct_answer_model_profile",
           status: :denied,
           permission: :settings_write,
           permission_decision: permission_decision,
           settings_metadata: %{direct_answer_model_profile: profile, error: reason}
         }
       ]
     }}
  end

  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)
    effect_context = Map.take(context, [:allbert_pack_epoch])

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id, :allbert_pack_epoch])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.merge(effect_context)
    |> Map.put(:permission_decision, permission_decision)
  end

  defp audit_paths(settings) do
    settings
    |> Enum.flat_map(& &1.diagnostics)
    |> Enum.flat_map(fn
      %{audit_path: audit_path} -> [audit_path]
      _diagnostic -> []
    end)
  end
end
