defmodule AllbertAssist.Actions.Settings.SetProviderCredential do
  @moduledoc false

  use Jido.Action,
    name: "set_provider_credential",
    description: "Guide explicit provider credential configuration.",
    category: "settings",
    tags: ["settings", "providers", "secrets"],
    schema: [
      provider: [type: :string, required: true],
      mode: [type: :atom, required: false],
      api_key: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.Secrets

  @impl true
  def run(%{provider: provider} = params, context) do
    mode = Map.get(params, :mode, :configure)

    case mode do
      :raw_prompt_secret ->
        deny_raw_prompt(provider, context)

      :raw_secret_read ->
        deny_secret_read(provider, context)

      :set_secret ->
        store_secret(provider, Map.get(params, :api_key), context)

      _mode ->
        credential_guidance(provider, context)
    end
  end

  defp store_secret(provider, api_key, context) when is_binary(api_key) do
    permission_decision = PermissionGate.authorize(:settings_secret_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <-
           Secrets.put_secret(
             secret_ref(provider),
             api_key,
             action_context(context, permission_decision)
           ) do
      {:ok,
       %{
         message: "Provider credential saved for #{provider}.",
         status: :completed,
         provider: provider,
         credential_status: result.status,
         diagnostics: Map.get(result, :diagnostics, []),
         actions: [
           action(
             provider,
             :completed,
             :settings_secret_write,
             permission_decision,
             :credential_saved,
             audit_path(result)
           )
         ]
       }}
    else
      false -> denied(provider, permission_decision, :permission_denied)
      {:error, reason} -> denied(provider, permission_decision, reason)
    end
  end

  defp store_secret(provider, _api_key, context) do
    permission_decision = PermissionGate.authorize(:settings_secret_write, context)
    denied(provider, permission_decision, :empty_provider_key)
  end

  defp credential_guidance(provider, context) do
    permission_decision = PermissionGate.authorize(:settings_secret_write, context)

    {:ok,
     %{
       message:
         "Credential entry for #{provider} must use the explicit CLI or LiveView secret form. Use `mix allbert.settings providers set-key #{provider}` or the Settings page provider key form.",
       status: PermissionGate.response_status(permission_decision),
       actions: [
         action(
           provider,
           :completed,
           :settings_secret_write,
           permission_decision,
           :credential_flow_guidance
         )
       ]
     }}
  end

  defp deny_raw_prompt(provider, context) do
    permission_decision = PermissionGate.authorize(:settings_secret_write, context)

    {:ok,
     %{
       message:
         "I will not store provider credentials from natural-language prompt text. Use the explicit CLI stdin prompt or the Settings page secret form so the value stays out of traces.",
       status: :denied,
       actions: [
         action(
           provider,
           :denied,
           :settings_secret_write,
           permission_decision,
           :raw_prompt_secret_refused
         )
       ]
     }}
  end

  defp deny_secret_read(provider, context) do
    permission_decision = PermissionGate.authorize(:settings_secret_read, context)

    {:ok,
     %{
       message:
         "I cannot display raw provider secrets. I can show only redacted credential status.",
       status: PermissionGate.response_status(permission_decision),
       actions: [
         action(
           provider,
           :denied,
           :settings_secret_read,
           permission_decision,
           :raw_secret_read_denied
         )
       ]
     }}
  end

  defp denied(provider, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not save provider credential for #{provider}: #{inspect(reason)}",
       status: :denied,
       provider: provider,
       credential_status: :missing,
       diagnostics: [],
       actions: [
         action(provider, :denied, :settings_secret_write, permission_decision, reason)
       ]
     }}
  end

  defp action(provider, status, permission, permission_decision, reason, audit_path \\ nil) do
    %{
      name: "set_provider_credential",
      status: status,
      permission: permission,
      permission_decision: permission_decision,
      settings_metadata: %{
        provider: provider,
        secret_status: :redacted,
        reason: reason,
        audit_path: audit_path
      }
    }
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

  defp audit_path(result) do
    result
    |> Map.get(:diagnostics, [])
    |> Enum.find_value(&Map.get(&1, :audit_path))
  end

  defp secret_ref(provider), do: "secret://providers/#{provider}/api_key"
end
