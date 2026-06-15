defmodule AllbertAssist.Actions.Channels.SetupCheck do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "channel_setup_check",
    description: "Check redacted setup readiness for one Allbert channel adapter.",
    category: "channels",
    tags: ["channels", "setup", "read_only"],
    schema: [channel: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Channels
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.Secrets

  @impl true
  def run(%{channel: channel}, context) when is_binary(channel) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, descriptor} <- Channels.channel_descriptor(channel),
         {:ok, settings} <- Channels.channel_settings(channel) do
      setup = setup_check(channel, descriptor, settings)

      {:ok,
       %{
         message: message(setup),
         status: :completed,
         setup: setup,
         actions: [
           action(:completed, permission_decision, %{
             channel: channel,
             setup_status: setup.setup_status,
             diagnostics: setup.diagnostics
           })
         ]
       }}
    else
      false ->
        denied(channel, permission_decision, :permission_denied)

      {:error, :unknown_channel} ->
        not_found(channel, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    denied(nil, permission_decision, :invalid_params)
  end

  defp setup_check(channel, descriptor, settings) do
    required_settings = required_settings(channel, settings)
    secret_status = secret_status(channel, descriptor, settings)
    diagnostics = diagnostics(required_settings, secret_status)

    %{
      channel: channel,
      provider: descriptor.provider,
      enabled: Map.get(settings, "enabled", false),
      setup_status: if(diagnostics == [], do: :ready, else: :incomplete),
      required_settings: required_settings,
      secret_status: secret_status,
      diagnostics: diagnostics,
      commands: commands(channel),
      manual_steps: manual_steps(channel),
      retry_posture: retry_posture(channel)
    }
  end

  defp required_settings("matrix", settings) do
    [
      setting("enabled", Map.get(settings, "enabled", false), required?: true),
      setting("homeserver_url", Map.get(settings, "homeserver_url"), required?: true),
      setting("access_token_ref", Map.get(settings, "access_token_ref"), required?: true),
      setting("allowed_room_ids", Map.get(settings, "allowed_room_ids", []), required?: true),
      setting("identity_map", Map.get(settings, "identity_map", []), required?: true)
    ]
  end

  defp required_settings("whatsapp", settings) do
    [
      setting("enabled", Map.get(settings, "enabled", false), required?: true),
      setting("access_token_ref", Map.get(settings, "access_token_ref"), required?: true),
      setting("phone_number_id", Map.get(settings, "phone_number_id"), required?: true),
      setting("waba_id", Map.get(settings, "waba_id"), required?: true),
      setting("webhook_enabled", Map.get(settings, "webhook_enabled", false), required?: true),
      setting("app_secret_ref", Map.get(settings, "app_secret_ref"), required?: true),
      setting(
        "webhook_verify_token_ref",
        Map.get(settings, "webhook_verify_token_ref"),
        required?: true
      ),
      setting("identity_map", Map.get(settings, "identity_map", []), required?: true)
    ]
  end

  defp required_settings("signal", settings) do
    control_mode = Map.get(settings, "control_mode", "socket")

    [
      setting("enabled", Map.get(settings, "enabled", false), required?: true),
      setting("account_identifier", Map.get(settings, "account_identifier"), required?: true),
      setting("local_aci", Map.get(settings, "local_aci"), required?: true),
      setting("control_mode", control_mode, required?: true),
      setting("identity_map", Map.get(settings, "identity_map", []), required?: true),
      setting("allowed_aci_ids", Map.get(settings, "allowed_aci_ids", []), required?: true)
    ] ++ signal_control_settings(control_mode, settings)
  end

  defp required_settings(_channel, settings) do
    [
      setting("enabled", Map.get(settings, "enabled", false), required?: true),
      setting("identity_map", Map.get(settings, "identity_map", []), required?: false)
    ]
  end

  defp signal_control_settings("loopback_http", settings) do
    [
      setting("loopback_http_base_url", Map.get(settings, "loopback_http_base_url"),
        required?: true
      ),
      setting("control_auth_ref", Map.get(settings, "control_auth_ref"), required?: true)
    ]
  end

  defp signal_control_settings("socket", settings) do
    [
      setting("data_dir", Map.get(settings, "data_dir"), required?: false),
      setting("socket_path", Map.get(settings, "socket_path"), required?: false)
    ]
  end

  defp signal_control_settings(_mode, _settings), do: []

  defp setting(name, value, opts) do
    %{
      name: name,
      required?: Keyword.fetch!(opts, :required?),
      configured?: configured?(value)
    }
  end

  defp secret_status(channel, descriptor, settings) do
    descriptor
    |> Map.get(:secret_refs, [])
    |> Enum.map(fn setting_path ->
      key = setting_path |> String.split(".") |> List.last()
      ref = Map.get(settings, key)

      %{
        name: setting_path,
        ref_configured?: configured?(ref),
        required?: secret_required?(channel, key, settings),
        status: secret_status(ref)
      }
    end)
  end

  defp secret_required?("signal", "control_auth_ref", settings) do
    Map.get(settings, "control_mode", "socket") == "loopback_http"
  end

  defp secret_required?("whatsapp", key, _settings)
       when key in ["access_token_ref", "app_secret_ref", "webhook_verify_token_ref"],
       do: true

  defp secret_required?("matrix", "access_token_ref", _settings), do: true
  defp secret_required?(_channel, _key, _settings), do: false

  defp secret_status(ref) when is_binary(ref) and ref != "", do: Secrets.status(ref)
  defp secret_status(_ref), do: :missing

  defp diagnostics(required_settings, secret_status) do
    setting_diagnostics =
      required_settings
      |> Enum.filter(&(&1.required? and not &1.configured?))
      |> Enum.map(&String.to_atom("missing_" <> &1.name))

    secret_diagnostics =
      secret_status
      |> Enum.filter(&(&1.required? and &1.status != :configured))
      |> Enum.map(&String.to_atom("missing_secret_" <> short_secret_name(&1.name)))

    setting_diagnostics ++ secret_diagnostics
  end

  defp short_secret_name(setting_path), do: setting_path |> String.split(".") |> List.last()

  defp configured?(true), do: true
  defp configured?(false), do: false
  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(value) when is_list(value), do: value != []
  defp configured?(nil), do: false
  defp configured?(_value), do: true

  defp commands("matrix") do
    %{
      set_secret: "mix allbert.channels matrix set-token <token>",
      doctor: "mix allbert.channels matrix doctor",
      smoke: "mix allbert.test external-smoke -- matrix"
    }
  end

  defp commands("whatsapp") do
    %{
      set_secret: "mix allbert.channels whatsapp set-token <token>",
      doctor: "mix allbert.channels whatsapp doctor",
      smoke: "mix allbert.test external-smoke -- whatsapp"
    }
  end

  defp commands("signal") do
    %{
      pair: "mix allbert.channels signal link --account <account>",
      doctor: "mix allbert.channels signal doctor",
      smoke: "mix allbert.test external-smoke -- signal"
    }
  end

  defp commands(channel) do
    %{
      show: "mix allbert.channels show #{channel}",
      smoke: "mix allbert.test external-smoke -- #{channel}"
    }
  end

  defp manual_steps("matrix") do
    [
      "Create or choose a Matrix bot account.",
      "Invite the bot to each allowed room.",
      "Map external MXIDs before accepting inbound requests."
    ]
  end

  defp manual_steps("whatsapp") do
    [
      "Configure the WABA phone number and app secret in Meta.",
      "Expose the webhook through the public protocol HTTPS endpoint or tunnel.",
      "Map sender phone numbers before accepting inbound requests."
    ]
  end

  defp manual_steps("signal") do
    [
      "Pair the local signal-cli account with the QR/device-link flow.",
      "Keep signal-cli data under ALLBERT_HOME with local socket or loopback control.",
      "Map ACI UUIDs before accepting inbound requests."
    ]
  end

  defp manual_steps(_channel), do: []

  defp retry_posture(channel) when channel in ["matrix", "whatsapp", "signal"] do
    %{
      automatic_provider_retry?: false,
      reason:
        "Outbound sends are not retried automatically; channel_events dedupe and failed status preserve retry evidence for explicit operator action."
    }
  end

  defp retry_posture(_channel), do: %{automatic_provider_retry?: false}

  defp message(setup) do
    missing =
      case setup.diagnostics do
        [] -> "none"
        diagnostics -> diagnostics |> Enum.map(&to_string/1) |> Enum.join(",")
      end

    "#{setup.channel} setup status=#{setup.setup_status} missing=#{missing}"
  end

  defp denied(channel, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not check channel setup #{inspect(channel)}: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, %{channel: channel, error: reason})]
     }}
  end

  defp not_found(channel, permission_decision) do
    {:ok,
     %{
       message: "Channel not found: #{channel}",
       status: :not_found,
       error: :unknown_channel,
       actions: [
         action(:not_found, permission_decision, %{channel: channel, error: :unknown_channel})
       ]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "channel_setup_check",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end
end
